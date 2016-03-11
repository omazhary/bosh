module Bosh::Director
  module DeploymentPlan
    class LinkPath
      attr_reader :deployment, :job, :template, :name, :path, :skip

      def initialize(deployment_plan, job_name, template_name)
        @deployment_plan = deployment_plan
        @consumes_job_name = job_name
        @consumes_template_name = template_name
        @deployment = nil
        @job = nil
        @template = nil
        @name = nil
        @path = nil
        @skip = false
      end

      def parse(link_info)
        # in case the link was explicitly set to the string 'nil', do not add it
        # to the link paths, even if the link provider exist, since the user intent
        # was explicitly set to not consume any link

        if link_info["skip_link"] && link_info["skip_link"] == true
          @skip = true
          return
        end

        if link_info.has_key?("from")
          link_path = fulfill_explicit_link(link_info)
        else
          link_path = fulfill_implicit_link(link_info)
        end
        if link_path != nil
          @deployment, @job, @template, @name = link_path.values_at(:deployment, :job, :template, :name)
          @path = "#{link_path[:deployment]}.#{link_path[:job]}.#{link_path[:template]}.#{link_path[:name]}"
        else
          @skip = true
        end
      end

      def to_s
        "#{deployment}.#{job}.#{template}.#{name}"
      end

      private

      def fulfill_implicit_link(link_info)
        link_type = link_info["type"]
        found_link_paths = []

        @deployment_plan.jobs.each do |provides_job|
          provides_job.templates.each do |provides_template|
            if provides_template.link_infos.has_key?(provides_job.name) && provides_template.link_infos[provides_job.name].has_key?('provides')
              matching_links = provides_template.link_infos[provides_job.name]["provides"].select { |k,v| v["type"] == link_type }
              if matching_links.size > 0
                link_name = matching_links.values()[0].has_key?("as") ? matching_links.values()[0]['as'] : matching_links.values()[0]['name']
                found_link_paths.push({:deployment => @deployment_plan.name, :job => provides_job.name, :template => provides_template.name, :name => link_name})
              end
            end
          end
        end

        if found_link_paths.size == 1
          return found_link_paths[0]
        elsif found_link_paths.size > 1
          all_link_paths = ""
          found_link_paths.each do |link_path|
            all_link_paths = all_link_paths + "\n   #{link_path[:deployment]}.#{link_path[:job]}.#{link_path[:template]}.#{link_path[:name]}"
          end
          raise "Multiple instance groups provide links of type '#{link_type}'. Cannot decide which one to use for instance group '#{@consumes_job_name}'.#{all_link_paths}"
        else
          # Only raise an exception if no linkpath was found, and the link is not optional
          if !link_info["optional"]
             raise "Can't find link with type: #{link_type} in deployment #{@deployment_plan.name}"
          end
        end
      end

      def fulfill_explicit_link(link_info)
        from_where = link_info['from']
        parts = from_where.split('.') # the string might be formatted like 'deployment.link_name'
        from_name = parts.shift

        if parts.size >= 1  # given a deployment name
          deployment_name = from_name
          from_name = parts.shift
          if parts.size >= 1
            raise "From string #{from_where} is poorly formatted. It should look like 'link_name' or 'deployment_name.link_name'"
          end

          if deployment_name == @deployment_plan.name
            link_path = get_link_path_from_deployment_plan(from_name)
          else
            link_path = find_deployment_and_get_link_path(deployment_name, from_name)
          end
        else  # given no deployment name
          link_path = get_link_path_from_deployment_plan(from_name)   # search the jobs for the current deployment for a provides
        end
        link_path[:name] = from_name
        return link_path
      end

      def get_link_path_from_deployment_plan(name)
        found_link_paths = []
        @deployment_plan.jobs.each do |job|
          job.templates.each do |template|
            if template.link_infos.has_key?(job.name) && template.link_infos[job.name].has_key?('provides')
              template.link_infos[job.name]['provides'].to_a.each do |provides_name, source|
                link_name = source.has_key?("as") ? source['as'] : source['name']
                if link_name == name
                  found_link_paths.push({:deployment => @deployment_plan.name, :job => job.name, :template => template.name, :name => name})
                end
              end
            end
          end
        end
        if found_link_paths.size == 1
          return found_link_paths[0]
        elsif found_link_paths.size > 1
          all_link_paths = ""
          found_link_paths.each do |link_path|
            all_link_paths = all_link_paths + "\n   #{link_path[:deployment]}.#{link_path[:job]}.#{link_path[:template]}.#{link_path[:name]}"
          end
          link_str = "#{@deployment_plan.name}.#{@consumes_job_name}.#{@consumes_template_name}.#{name}"
          raise "Cannot resolve ambiguous link '#{link_str}' in deployment #{@deployment_plan.name}:#{all_link_paths}"
        else
          raise "Can't resolve link '#{name}' in instance group '#{@consumes_job_name}' on job '#{@consumes_template_name}' in deployment '#{@deployment_plan.name}'"
        end
      end

      def find_deployment_and_get_link_path(deployment_name, name)
        deployment_model = Models::Deployment.where(:name => deployment_name)

        # get the link path from that deployment
        if deployment_model.count != 0
          return find_link_path_with_name(deployment_model.first, name)
        else
          raise "Can't find deployment #{deployment_name}"
        end
      end

      def find_link_path_with_name(deployment, name)
        deployment_link_spec = deployment.link_spec
        found_link_paths = []
        deployment_link_spec.keys.each do |job|
          deployment_link_spec[job].keys.each do |template|
            deployment_link_spec[job][template].keys.each do |link|
              if link == name
                found_link_paths.push({:deployment => deployment.name, :job => job, :template => template, :name => name})
              end
            end
          end
        end
        if found_link_paths.size == 1
          return found_link_paths[0]
        elsif found_link_paths.size > 1
          all_link_paths = ""
          found_link_paths.each do |link_path|
            all_link_paths = all_link_paths + "\n   #{link_path[:deployment]}.#{link_path[:job]}.#{link_path[:template]}.#{link_path[:name]}"
          end
          link_str = "#{@deployment_plan.name}.#{@consumes_job_name}.#{@consumes_template_name}.#{name}"
          raise "Cannot resolve ambiguous link '#{link_str}' in deployment #{deployment.name}:#{all_link_paths}"
        else
          raise "Can't resolve link '#{name}' in instance group '#{@consumes_job_name}' on job '#{@consumes_template_name}' in deployment '#{@deployment_plan.name}'. Please make sure the link was provided and shared."
        end
      end

    end
  end
end
