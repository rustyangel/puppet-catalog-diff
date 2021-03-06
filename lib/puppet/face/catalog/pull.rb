require 'puppet/face'
require 'thread'
require 'digest'
#require 'puppet/application/master'

Puppet::Face.define(:catalog, '0.0.1') do
  action :pull do
    description "Pull catalogs from duel puppet masters"
    arguments "/tmp/old_catalogs /tmp/new_catalogs"

    option "--old_server=" do
      required
      summary "This the valid certificate name or alt name for your old server"
    end

    option "--new_server=" do
      summary "This the valid certificate name or alt name for your old server"

      default_to { Facter.value("fqdn") }
    end

    option "--threads" do
      summary "The number of threads to use"
      default_to { '10' }
    end

    option "--use_puppetdb" do
      summary "Use puppetdb to do the fact search instead of the rest api"
    end

    option "--filter_local" do
      summary "Use local YAML node files to filter out queried nodes"
    end

    option "--changed_depth=" do
      summary "The number of problem files to display sorted by changes"

      default_to { '10' }
    end

    description <<-'EOT'
      This action is used to seed a series of catalogs from two servers
    EOT
    notes <<-'NOTES'
      This will store files in pson format with the in the save directory. i.e.
      <path/to/seed/directory>/<node_name>.pson . This is currently the only format
      that is supported.

    NOTES
    examples <<-'EOT'
      Dump host catalogs:

      $ puppet catalog pull /tmp/old_catalogs /tmp/new_catalogs kernel=Linux --old_server puppet2.puppetlabs.vm --new_server puppet3.puppetlabs.vm
    EOT

    when_invoked do |catalog1,catalog2,args,options|
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "searchfacts.rb"))
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "compilecatalog.rb"))
      unless nodes = Puppet::CatalogDiff::SearchFacts.new(args).find_nodes(options)
        raise "Problem finding nodes with query #{args}"
      end
      total_nodes = nodes.size
      thread_count = options[:threads].to_i
      compiled_nodes = []
      failed_nodes = {}
      mutex = Mutex.new

      thread_count.times.map {
        Thread.new(nodes,compiled_nodes,options) do |nodes,compiled_nodes,options|
         Puppet.debug(nodes)
         while node_name = mutex.synchronize { nodes.pop }
            begin
              if nodes.size.odd?
                old_server = Puppet::Face[:catalog, '0.0.1'].seed(catalog1,node_name,:master_server => options[:old_server] )
                new_server = Puppet::Face[:catalog, '0.0.1'].seed(catalog2,node_name,:master_server => options[:new_server] )
              else
                new_server = Puppet::Face[:catalog, '0.0.1'].seed(catalog2,node_name,:master_server => options[:new_server] )
                old_server = Puppet::Face[:catalog, '0.0.1'].seed(catalog1,node_name,:master_server => options[:old_server] )
              end
              mutex.synchronize { compiled_nodes + old_server[:compiled_nodes] }
              mutex.synchronize { compiled_nodes + new_server[:compiled_nodes] }
              mutex.synchronize { new_server[:failed_nodes][node_name].nil? || failed_nodes[node_name] = new_server[:failed_nodes][node_name] }
            rescue Exception => e
              Puppet.err(e.to_s)
            end
          end
        end
      }.each(&:join)
      output = {}
      output[:failed_nodes]         = failed_nodes
      output[:failed_nodes_total]   = failed_nodes.size
      output[:compiled_nodes]       = compiled_nodes.compact
      output[:compiled_nodes_total] = compiled_nodes.compact.size
      output[:total_nodes]          = total_nodes
      output[:total_percentage]     = (failed_nodes.size.to_f / total_nodes.to_f) * 100
      problem_files = {}

      failed_nodes.each do |node_name,error|
        # Extract the filename and the node a key of the same name
        match = /(\S*(\/\S*\.pp|\.erb))/.match(error.to_s)
        if match
          (problem_files[match[1]] ||= []) << node_name
        else
          unique_token = Digest::MD5.hexdigest(error.to_s.gsub(node_name,''))
          (problem_files["No-path-in-error-#{unique_token}"] ||= []) << node_name
        end
      end

      most_changed = problem_files.sort_by {|file,nodes| nodes.size }.map do |file,nodes|
         Hash[file => nodes.size]
      end

      output[:failed_to_compile_files]    = most_changed.reverse.take(options[:changed_depth].to_i)

      example_errors = output[:failed_to_compile_files].map do |file_hash|
        example_error = file_hash.map do |file_name,metric|
           example_node = problem_files[file_name].first
           error        = failed_nodes[example_node].to_s
           Hash[error => example_node]
        end.first
        example_error
      end
      output[:example_compile_errors] = example_errors
      output
    end
    when_rendering :console do |output|
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "formater.rb"))
      format = Puppet::CatalogDiff::Formater.new()
      output.collect do |key,value|
        if value.is_a?(Array)  && key == :failed_to_compile_files
          format.list_file_hash(key,value)
        elsif value.is_a?(Array) && key == :example_compile_errors
          format.list_error_hash(key,value)
        end
      end.join("\n")
    end
  end
end
