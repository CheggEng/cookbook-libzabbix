action :create_or_update do
  Chef::Zabbix.with_connection(new_resource.server_connection) do |connection|
    get_host_request = {
      :method => 'host.get',
      :params => {
        :filter => {
          :host => new_resource.hostname
        },
        :selectParentTemplates => ['host'],
        :selectInterfaces => ['main', 'type', 'useip', 'ip', 'dns', 'port'],
        :selectGroups => ['name']
      }
    }
    hosts = connection.query(get_host_request)

    if hosts.size == 0
      Chef::Log.info 'Proceeding to register this node to the Zabbix server'
      run_action :create
    else
      update_host = false

      # Compare templates
      current_templates = []
      hosts[0]['parentTemplates'].each do |tmpl|
        current_templates << tmpl['host']
      end

      if current_templates.sort != new_resource.templates.sort
        update_host = true
        Chef::Log.debug 'Current templates and new templates differ'
      end

      # Compare groups
      current_groups = []
      hosts[0]['groups'].each do |grp|
        current_groups << grp['name']
      end

      if current_groups.sort != new_resource.groups.sort
        update_host = true
        Chef::Log.debug 'Current groups and new groups differ'
      end

      # Compare interfaces
      new_interfaces = []
      new_resource.interfaces.each do |int|
        new_interfaces << {
          'type'  => int[:type].value.to_s,
          'main'  => int[:main].to_s,
          'ip'    => int[:ip],
          'dns'   => int[:dns],
          'port'  => int[:port].to_s,
          'useip' => int[:useip].to_s
        }
      end

      # New interfaces that do not yet exist?
      found = false
      new_interfaces.each do |new_int|
        hosts[0]['interfaces'].each do|cur_int|
          if new_int.eql?(cur_int)
            found = true
            break
          end
        end
      end

      unless found
        update_host = true
        Chef::Log.debug 'New hostinterface required'
      end

      # Existing interfaces that should be removed?
      found = false
      hosts[0]['interfaces'].each do |cur_int|
        new_interfaces.each do|new_int|
          if new_int.eql?(cur_int)
            found = true
            break
          end
        end
      end

      unless found
        update_host = true
        Chef::Log.debug 'Hostinterface to be removed'
        #Chef::Log.debug cur_int
      end

      if update_host
        Chef::Log.debug 'Going to update this host'
        run_action :update
        new_resource.updated_by_last_action(true)
      end
    end
  end
end

action :create do
  Chef::Zabbix.with_connection(new_resource.server_connection) do |connection|
    all_are_host_interfaces = new_resource.interfaces.all? { |interface| interface.is_a?(Chef::Zabbix::API::HostInterface) }
    unless all_are_host_interfaces
      Chef::Application.fatal!(':interfaces must only contain Chef::Zabbix::API::HostInterface')
    end

    Chef::Log.error('Please supply a group for this host!') if new_resource.groups.empty? && new_resource.parameters[:groupNames].empty?

    if new_resource.groups.empty?
      group_names = new_resource.parameters[:groupNames]
    else
      group_names = new_resource.groups
    end

    groups = []
    group_names.each do |current_group|
      Chef::Log.info "Checking for existence of group #{current_group}"
      get_groups_request = {
        :method => 'hostgroup.get',
        :params => {
          :filter => {
            :name => current_group
          }
        }
      }
      groups = connection.query(get_groups_request)
      if groups.length == 0 && new_resource.create_missing_groups
        Chef::Log.info "Creating group #{current_group}"
        make_groups_request = {
          :method => 'hostgroup.create',
          :params => {
            :name => current_group
          }
        }
        result = connection.query(make_groups_request)
        # And now fetch the newly made group to be sure it worked
        # and for later use
        groups = connection.query(get_groups_request)
        Chef::Log.error('Error creating groups, see Chef errors') if result.nil?
      elsif groups.length == 1
        Chef::Log.info "Group #{current_group} already exists"
      else
        Chef::Application.fatal! "Could not find group, #{current_group}, for this host and \"create_missing_groups\" is False (or unset)"
      end
    end

    if new_resource.templates.empty?
      template_names = new_resource.parameters[:templates]
    else
      template_names = new_resource.templates
    end
    desired_templates = template_names.reduce([]) do |acc, desired_template|
      get_desired_templates_request = {
        :method => 'template.get',
        :params => {
          :filter => {
            :host => desired_template
          }
        }
      }
      template = connection.query(get_desired_templates_request)
      acc << template
    end

    if new_resource.interfaces.empty?
      interfaces = new_resource.parameters[:interfaces]
    else
      interfaces = new_resource.interfaces
    end

    request = {
      :method => 'host.create',
      :params => {
        :host => new_resource.hostname,
        :groups => groups,
        :templates => desired_templates.flatten,
        :interfaces => interfaces.map(&:to_hash),
        :inventory_mode => 1,
        :macros => format_macros(new_resource.macros)
      }
    }

    #Set proxy if we have one
    if !new_resource.parameters[:proxy].empty?
      #find proxy_host_id
      get_proxy_host_id = {
        :method => 'proxy.get',
        :params => {
          :filter => {
            :host => new_resource.parameters[:proxy]
          },
          :output           => 'extend',
          :selectInterfaces => 'extend',
        }
      }
      proxy = connection.query(get_proxy_host_id)

      if !proxy.nil?
        if !proxy[0]['proxyid'].nil?
          #parse proxy host id
          request[:params][:proxy_hostid] = proxy[0]['proxyid']
        end
      end
    end

    Chef::Log.debug "Creating new Zabbix entry for this host: #{request}"
    connection.query(request)
  end
  new_resource.updated_by_last_action(true)
end

action :update do
  Chef::Zabbix.with_connection(new_resource.server_connection) do |connection|
    get_host_request = {
      :method => 'host.get',
      :params => {
        :filter => {
          :host => new_resource.hostname
        },
        :selectInterfaces => 'extend',
        :selectGroups => 'extend',
        :selectParentTemplates => 'extend'
      }
    }
    host = connection.query(get_host_request).first
    if host.nil?
      Chef::Application.fatal! "Could not find host #{new_resource.hostname}"
    end

    if new_resource.groups.empty?
      group_names = new_resource.parameters[:groupNames]
    else
      group_names = new_resource.groups
    end

    desired_groups = group_names.reduce([]) do |acc, desired_group|
      get_desired_groups_request = {
        :method => 'hostgroup.get',
        :params => {
          :filter => {
            :name => desired_group
          }
        }
      }
      group = connection.query(get_desired_groups_request).first
      #if group missing, create it
      if group.nil? && new_resource.create_missing_groups
        Chef::Log.info "Creating group #{desired_group}"
        make_groups_request = {
          :method => 'hostgroup.create',
          :params => {
            :name => desired_group
          }
        }
        result = connection.query(make_groups_request)
        # And now fetch the newly made group to be sure it worked
        # and for later use
        group = connection.query(get_desired_groups_request)
        Chef::Log.error('Error creating groups, see Chef errors') if result.nil?
      elsif !group['name'].nil?
        Chef::Log.info "Group #{desired_group} already exists"
      else
        Chef::Application.fatal! "Could not find group, #{desired_group}, for this host and \"create_missing_groups\" is False (or unset)"
      end
      acc << group
    end

    if new_resource.templates.empty?
      template_names = new_resource.parameters[:templates]
    else
      template_names = new_resource.templates
    end
    desired_templates = template_names.reduce([]) do |acc, desired_template|
      get_desired_templates_request = {
        :method => 'template.get',
        :params => {
          :filter => {
            :host => desired_template
          }
        }
      }
      template = connection.query(get_desired_templates_request)
      acc << template
    end

    if new_resource.interfaces.empty?
      interfaces = new_resource.parameters[:interfaces]
    else
      interfaces = new_resource.interfaces
    end

    #Lets debug logs
    Chef::Log.warn "Interface list: #{interfaces}"

    existing_interfaces = host['interfaces'].map { |interface| Chef::Zabbix::API::HostInterface.from_api_response(interface).to_hash }
    new_host_interfaces = determine_new_host_interfaces(existing_interfaces, interfaces.map(&:to_hash))
    new_host_interfaces.each do |interface|
      create_interface_request = {
        :method => 'hostinterface.create',
        :params => interface.merge(:hostid => host['hostid'])

      }
      Chef::Log.warn "Creating new interface on #{host['hostid']}: #{interface}"
      connection.query(create_interface_request)
    end

    host_update_request = {
      :method => 'host.update',
      :params => {
        :hostid => host['hostid'],
        :groups => desired_groups,
        :inventory_mode => 1,
        :templates => desired_templates.flatten,
      }
    }

    #Set proxy if we have one
    if !new_resource.parameters[:proxy].empty?
      #find proxy_host_id
      get_proxy_host_id = {
        :method => 'proxy.get',
        :params => {
          :filter => {
            :host => new_resource.parameters[:proxy]
          },
          :output           => 'extend',
          :selectInterfaces => 'extend',
        }
      }
      proxy = connection.query(get_proxy_host_id)

      if !proxy.nil?
        if !proxy[0]['proxyid'].nil?
          #parse proxy host id
          host_update_request[:params][:proxy_hostid] = proxy[0]['proxyid']
        end
      end
    end
    Chef::Log.debug "Updating zabbix with: #{host_update_request}"

    result = connection.query(host_update_request)

  end
  new_resource.updated_by_last_action(true)
end

def load_current_resource
  run_context.include_recipe 'libzabbix::_providers_common'
  require 'zabbixapi'
end

def determine_new_host_interfaces(existing_interfaces, desired_interfaces)
  desired_interfaces.reject do |desired_interface|
    existing_interfaces.any? do |existing_interface|
      existing_interface['type'] == desired_interface['type'] &&
        existing_interface['port'] == desired_interface['port']
    end
  end
end

def format_macros(macros)
  macros.map do |macro, value|
    macro_name = (macro[0] == '{') ? macro : "{$#{macro}}"
    {
      :macro => macro_name,
      :value => value
    }
  end
end
