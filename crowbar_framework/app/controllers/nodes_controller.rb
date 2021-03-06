#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class NodesController < ApplicationController
  # allow node polling during the upgrade
  skip_before_filter :upgrade, only: [:index]

  api :GET, "/nodes", "List all nodes and their status"
  header "Accept", "application/json", required: true
  example '
  {
    "d52-54-77-77-77-01": {
      "alias": "d52-54-77-77-77-01",
      "description": null,
      "status": "unknown",
      "state": "shutdown"
    },
    "d52-54-77-77-77-02": {
      "alias": "d52-54-77-77-77-02",
      "description": null,
      "status": "unknown",
      "state": "shutdown"
    },
    "crowbar": {
      "alias": "crowbar",
      "description": null,
      "status": "ready",
      "state": "ready"
    }
  }
  '
  def index
    @sum = 0
    @groups = {}
    session[:node] = params[:name]
    if params.key?(:role)
      result = Node.all # this is not efficient, please update w/ a search!
      @nodes = result.find_all { |node| node.role? params[:role] }
      if params.key?(:names_only)
         names = @nodes.map { |node| node.handle }
         @nodes = {role: params[:role], nodes: names, count: names.count}
      end
    else
      @nodes = {}
      get_nodes_and_groups(params[:name])
      flash[:notice] = "<b>#{t :warning, scope: :error}:</b> #{t :no_nodes_found, scope: :error}" if @nodes.empty? #.html_safe if @nodes.empty?
    end

    respond_to do |format|
      format.html
      format.xml { render xml: @nodes }
      format.json { render json: @nodes }
    end
  end

  def list
    @allocated = true

    @nodes = {}.tap do |nodes|
      Node.all.each do |node|
        nodes[node.handle] = node
      end
    end

    respond_to do |format|
      format.html { render "list" }
    end
  end

  def unallocated
    @allocated = false

    @nodes = {}.tap do |nodes|
      Node.all.each do |node|
        unless node.allocated?
          nodes[node.handle] = node
        end
      end
    end

    respond_to do |format|
      format.html { render "list" }
    end
  end

  def bulk
    @report = {
      success: [],
      failed: [],
      duplicate_public: false,
      duplicate_alias: false,
      group_error: false
    }.tap do |report|
      node_values = params[:node] || {}

      node_aliases = node_values.values.map do |attributes|
        attributes["alias"]
      end

      node_publics = node_values.values.map do |attributes|
        attributes["public_name"]
      end

      node_values.each do |node_name, node_attributes|
        if not node_attributes["public_name"].to_s.empty? and node_publics.grep(node_attributes["public_name"]).size > 1
          report[:duplicate_public] = true
          report[:failed].push node_name
        end

        if node_aliases.grep(node_attributes["alias"]).size > 1
          report[:duplicate_alias] = true
          report[:failed].push node_name
        end
      end

      unless report[:duplicate_alias] or report[:duplicate_public]
        node_values.each do |node_name, node_attributes|
          begin
            dirty = false
            node = Node.find_by_name(node_name)
            is_allocated = node.allocated?

            if node_attributes["allocate"] and not is_allocated
              node.allocate!
              dirty = true
            end

            unless is_allocated || node.admin?
              unless node.target_platform == node_attributes["target_platform"]
                node.target_platform = node_attributes["target_platform"]
                dirty = true
              end

              unless node.license_key == node_attributes["license_key"]
                node.license_key = node_attributes["license_key"]
                dirty = true
              end
            end

            unless node.alias == node_attributes["alias"]
              node.force_alias = node_attributes["alias"]
              dirty = true
            end

            unless node.public_name.blank? && node_attributes["public_name"].blank?
              unless node.public_name == node_attributes["public_name"]
                node.force_public_name = node_attributes["public_name"]
                dirty = true
              end
            end

            unless node.intended_role == node_attributes["intended_role"]
              node.intended_role = node_attributes["intended_role"]
              dirty = true
            end

            if dirty
              node.save
              report[:success].push node_name
            end
          rescue StandardError => e
            log_exception(e)
            report[:failed].push node_name
          end
        end
      end
    end

    if @report[:failed].length > 0
      node_list = @report[:failed].map do |node_name|
        node_name.split(".").first
      end

      translation = case
      when @report[:duplicate_alias]
        "nodes.list.duplicate_alias"
      when @report[:duplicate_publics]
        "nodes.list.duplicate_public"
      when @report[:group_error]
        "nodes.list.group_error"
      else
        "nodes.list.failed"
      end

      flash[:alert] = I18n.t(translation, failed: node_list.to_sentence)
    elsif @report[:success].length > 0
      node_list = @report[:success].map do |node_name|
        node_name.split(".").first
      end

      flash[:notice] = I18n.t("nodes.list.updated", success: node_list.to_sentence)
    else
      flash[:info] = I18n.t("nodes.list.nochange")
    end

    redirect_to params[:return] != "true" ? unallocated_nodes_path : list_nodes_path
  end

  def families
    @families = {}.tap do |families|
      Node.all.each do |node|
        family = node.family.to_s

        unless families.key? family
          families[family] = {
            names: [],
            family: node.family
          }
        end

        families[family][:names].push({
          alias: node.alias,
          description: node.description,
          handle: node.handle
        })
      end
    end

    #UI-only method
    respond_to do |format|
      format.html
    end
  end

  api :POST, "/nodes/groups/1.0/:id/:group", "Add a node to a group"
  header "Accept", "application/json", required: true
  param :id, String, desc: "Node name or alias", required: true
  param :group, String, desc: "Group name", required: true
  error 404, "Node not found"
  def group_change
    Node.find_node_by_name_or_alias(params[:id]).tap do |node|
      raise ActionController::RoutingError.new("Not Found") if node.nil?

      if params[:group].downcase.eql? "automatic"
        node.group = ""
      else
        node.group = params[:group]
      end

      node.save

      respond_to do |format|
        format.html do
          flash[:success] = I18n.t(
            "nodes.group_change.updated",
            name: node.name,
            group: node.group
          )

          redirect_to dashboard_index_url
        end
        format.json do
          render json: {
            group: node.group
          }
        end
      end
    end
  end

  api :GET, "/nodes/status", "Show the status of all nodes"
  header "Accept", "application/json", required: true
  example '
  {
    "nodes": {
      "d52-54-77-77-77-01": {
        "class": "unknown",
        "status": "Power Off"
      },
      "d52-54-77-77-77-02": {
        "class": "unknown",
        "status": "Power Off"
      },
      "crowbar": {
        "class": "ready",
        "status": "Ready"
      }
    },
    "groups": {
      "sw-unknown": {
        "tooltip": "<strong>Total 3</strong><br />1 Ready<br />2 Not Ready",
        "status": {
          "ready": 1,
          "failed": 0,
          "pending": 0,
          "unready": 0,
          "building": 0,
          "crowbar_upgrade": 0,
          "unknown": 2
        }
      }
    }
  }
  '
  def status
    @result = {
      nodes: {},
      groups: {}
    }.tap do |result|
      begin
        Node.all.each do |node|
          group_name = node.group || I18n.t("unknown")

          result[:groups][group_name] ||= begin
            {
              tooltip: "",
              status: {
                "ready" => 0,
                "failed" => 0,
                "pending" => 0,
                "unready" => 0,
                "building" => 0,
                "crowbar_upgrade" => 0,
                "unknown" => 0
              }
            }
          end

          result[:groups][group_name].tap do |group|
            group[:status][node.status] = group[:status][node.status] + 1
            group[:tooltip] = view_context.piechart_tooltip(view_context.piechart_values(group))
          end

          result[:nodes][node.handle] = {
            class: node.status,
            status: I18n.t(node.state, scope: :state, default: node.state.titlecase)
          }
        end
      rescue => e
        log_exception(e)
        result[:error] = e.message
      end
    end

    respond_to do |format|
      format.json { render json: @result }
    end
  end

  api :GET, "/nodes/:id/hit/:req",
    "Perform actions on a node. Actions are defined in the MachinesController"
  header "Accept", "application/json", required: true
  param :id, String, desc: "Node name", required: true
  param :req, [
    :reinstall,
    :reset,
    :shutdown,
    :reboot,
    :poweron,
    :powercycle,
    :poweroff,
    :allocate,
    :delete,
    :identify,
    :update
  ], desc: "Action that needs to be performed on the node", required: true
  def hit
    name = params[:name] || params[:id]
    machine = Node.find_by_name(name)

    respond_to do |format|
      format.json do
        if machine.nil?
          render json: {
            error: I18n.t("nodes.hit.not_found", name: name)
          }, status: :not_found
        elsif machine.actions.include? params[:req].to_s
          machine.send params[:req].to_sym
          head :ok
        else
          render json: {
            error: I18n.t("nodes.hit.invalid_req", req: params[:req])
          }, status: :internal_server_error
        end
      end

      format.html do
        if machine.nil?
          flash[:alert] = I18n.t("nodes.hit.not_found", name: name)
          redirect_to dashboard_index_url, status: :not_found
        elsif machine.actions.include? params[:req].to_s
          machine.send params[:req].to_sym
          redirect_to node_url(machine.handle)
        else
          flash[:alert] = I18n.t("nodes.hit.invalid_req", req: params[:req])
          redirect_to dashboard_index_url, status: :internal_server_error
        end
      end
    end
  end

  api :GET, "/nodes/:id", "Show details of a node"
  header "Accept", "application/json", required: true
  param :id, String, desc: "Node name", required: true
  example '
  {
    "chef_type": "node",
    "name": "admin.crowbar.com",
    "chef_environment": "_default",
    "languages": {
      "ruby": {
        "platform": "x86_64-linux-gnu",
        "version": "2.1.2",
        "release_date": "2014-05-08",
        "target": "x86_64-suse-linux-gnu",
        "target_cpu": "x86_64",
        "target_vendor": "suse",
        "target_os": "linux-gnu",
        "host": "x86_64-suse-linux-gnu",
        "host_cpu": "x86_64",
        "host_os": "linux-gnu",
        "host_vendor": "suse",
        "bin_dir": "/usr/bin",
        "ruby_bin": "/usr/bin/ruby.ruby2.1",
        "gems_dir": "/usr/lib64/ruby/gems/2.1.0",
        "gem_bin": "/usr/bin/gem.ruby2.1"
      },
      "perl": {
        "version": "5.18.2",
        "archname": "x86_64-linux-thread-multi"
      },
      "python": {
        "version": "2.7.9",
        "builddate": "Dec 21 2014, 11:02:59"
      },
      "nodejs": {
        "version": "4.4.7"
      }
    },
    ...
  }
  '
  error 404, "Node not found"
  def show
    get_node_and_network(params[:id] || params[:name])
    if @node.nil?
      msg = "Node #{params[:id] || params[:name]}: not found"
      if request.format == "html"
        flash[:notice] = msg
        return redirect_to nodes_path
      else
        raise ActionController::RoutingError.new(msg)
      end
    end
    get_nodes_and_groups(params[:name], false)
    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render xml: @node }
      format.json { render json: (params[:key].nil? ? @node : @node[params[:key]]) }
    end
  end

  def edit
    get_node_and_network(params[:id] || params[:name])
    if @node.nil?
      flash[:alert] = "Node #{params[:id] || params[:name]} not found."
      return redirect_to nodes_path
    end
  end

  def update
    unless request.post?
      raise ActionController::UnknownHttpMethod.new("POST is required to update proposal #{params[:id]}")
    end

    get_node_and_network(params[:id] || params[:name])
    raise ActionController::RoutingError.new("Node #{params[:id] || params[:name]} not found.") if @node.nil?

    if params[:submit] == t("nodes.form.allocate")
      if save_node
        @node.allocate!
        flash[:notice] = t("nodes.form.allocate_node_success")
      end
    elsif params[:submit] == t("nodes.form.save")
      flash[:notice] = t("nodes.form.save_node_success") if save_node
    else
      Rails.logger.warn "Unknown action for node edit: #{params[:submit]}"
      flash[:notice] = "Unknown action: #{params[:submit]}"
    end
    redirect_to node_path(@node.handle)
  end

  #this code allow us to get values of attributes by path of node
  def attribute
    @node = Node.find_by_name(params[:name])
    raise ActionController::RoutingError.new("Node #{params[:name]} not found.") if @node.nil?
    @attribute = @node.to_hash
    (params[:path] || "").split("/").each do |element|
      @attribute = @attribute[element]
      raise ActionController::RoutingError.new("Node #{params[:name]}: unknown attribute #{params[:path].join('/')}") if @attribute.nil?
    end
    render json: {value: @attribute}
  end

  private

  def save_node
    if params[:group] and params[:group] != "" and !(params[:group] =~ /^[a-zA-Z][a-zA-Z0-9._:-]+$/)
      flash[:alert] = t("nodes.list.group_error", failed: @node.name)
      return false
    end

    # if raid is selected, we need a couple of selected disks
    raid_disks_selected = params.fetch(:raid_disks, []).length
    if (params[:raid_type] == "raid1" and raid_disks_selected < 2) or \
      (params[:raid_type] == "raid5" and raid_disks_selected < 3) or \
      (params[:raid_type] == "raid6" and raid_disks_selected < 4) or \
      (params[:raid_type] == "raid10" and raid_disks_selected < 4)
      flash[:alert] = t("nodes.form.raid_disks_selected", node: @node.name)
      return false
    end

    begin
      # if we don't have OpenStack, availability_zone will be empty; which is
      # okay, because we don't care about this in that case
      {
        bios_set: :bios,
        raid_set: :raid,
        alias: :alias,
        public_name: :public_name,
        group: :group,
        description: :description,
        availability_zone: :availability_zone,
        intended_role: :intended_role,
        default_fs: :default_fs,
        raid_type: :raid_type,
        raid_disks: :raid_disks
      }.each do |attr, param|
        @node.send("#{attr}=", params[param]) if params.key?(param)
      end

      unless @node.allocated?
        @node.target_platform = params[:target_platform] || view_context.default_platform
        @node.license_key = params[:license_key]
      end
      @node.save
      true
    rescue StandardError => e
      log_exception(e)
      flash[:alert] = I18n.t("nodes.form.failed",
                             node: @node.name,
                             message: e.message)
      false
    end
  end

  def get_node_and_network(node_name)
    network = {}
    @network = []
    @node = Node.find_by_name(node_name) if @node.nil?
    if @node
      # If we're in discovery mode, then we have a temporary DHCP IP address.
      if !["discovering", "discovered"].include?(@node.state)
        # build network information (this may need to move into the object)
        @node.networks.each do |name, data|
          if name == "bmc"
            ifname = "bmc"
            address = @node["crowbar_wall"]["ipmi"]["address"] rescue nil
          else
            ifname, ifs, _team = @node.conduit_details(data["conduit"])
            if ifname.nil? or ifs.nil?
              ifname = "Unknown"
            else
              ifname = "#{ifname}[#{ifs.join(",")}]" if ifs.length > 1
            end
            address = data["address"]
          end
          if address
            network[name] ||= {}
            network[name][ifname] = address
          end
        end
        @network = network.sort
        @network << ["[not managed]", @node.unmanaged_interfaces] unless @node.unmanaged_interfaces.empty?
      elsif @node.state == "discovering"
        @network = [["[dhcp]", "discovering"]]
      else
        @network = [["[dhcp]", @node[:ipaddress]]]
      end
    end

    @network
  end

  def get_nodes_and_groups(node_name, draggable = true)
    @sum = 0
    @groups = {}
    @nodes  = {}
    raw_nodes = Node.all
    raw_nodes.each do |node|
      @sum = @sum + node.name.hash
      @nodes[node.handle] = { alias: node.alias, description: node.description, status: node.status, state: node.state }
      group = node.group
      @groups[group] = { automatic: !node.display_set?("group"),
                         status: { "ready" => 0,
                                   "failed" => 0,
                                   "unknown" => 0,
                                   "unready" => 0,
                                   "pending" => 0,
                                   "crowbar_upgrade" => 0 },
                         nodes: {}
                       } unless @groups.key? group
      @groups[group][:nodes][node.group_order] = node.handle
      @groups[group][:status][node.status] = (@groups[group][:status][node.status] || 0).to_i + 1
      if node.handle === node_name
        @node = node
        get_node_and_network(node.handle)
      end
    end
    @draggable = draggable
  end
end
