require 'erb'

module ThinkingSphinx
  # This class both keeps track of the configuration settings for Sphinx and
  # also generates the resulting file for Sphinx to use.
  # 
  # Here are the default settings, relative to RAILS_ROOT where relevant:
  #
  # config file::           config/#{environment}.sphinx.conf
  # searchd log file::      log/searchd.log
  # query log file::        log/searchd.query.log
  # pid file::              log/searchd.#{environment}.pid
  # searchd files::         db/sphinx/#{environment}/
  # address::               0.0.0.0 (all)
  # port::                  3312
  # allow star::            false
  # min prefix length::     0
  # min infix length::      0
  # mem limit::             64M
  # max matches::           1000
  # morphology::            stem_en
  # charset type::          utf-8
  # charset table::         nil
  # ignore chars::          nil
  # html strip::            false
  # html remove elements::  ''
  #
  # If you want to change these settings, create a YAML file at
  # config/sphinx.yml with settings for each environment, in a similar
  # fashion to database.yml - using the following keys: config_file,
  # searchd_log_file, query_log_file, pid_file, searchd_file_path, port,
  # allow_star, min_prefix_len, min_infix_len, mem_limit, max_matches,
  # morphology, charset_type, charset_table, ignore_chars, html_strip,
  # html_remove_elements. I think you've got
  # the idea.
  # 
  # Each setting in the YAML file is optional - so only put in the ones you
  # want to change.
  #
  # Keep in mind, if for some particular reason you're using a version of
  # Sphinx older than 0.9.8 r871 (that's prior to the proper 0.9.8 release),
  # don't set allow_star to true.
  # 
  class Configuration
    attr_accessor :config_file, :searchd_log_file, :query_log_file,
      :pid_file, :searchd_file_path, :address, :port, :allow_star,
      :min_prefix_len, :min_infix_len, :mem_limit, :max_matches, :morphology,
      :charset_type, :charset_table, :ignore_chars, :html_strip,
      :html_remove_elements, :app_root
    
    attr_reader :environment
    
    # Load in the configuration settings - this will look for config/sphinx.yml
    # and parse it according to the current environment.
    # 
    def initialize(app_root = Dir.pwd)
      self.app_root          = RAILS_ROOT if defined?(RAILS_ROOT)
      self.app_root          = Merb.root  if defined?(Merb)
      self.app_root        ||= app_root
      
      self.config_file          = "#{self.app_root}/config/#{environment}.sphinx.conf"
      self.searchd_log_file     = "#{self.app_root}/log/searchd.log"
      self.query_log_file       = "#{self.app_root}/log/searchd.query.log"
      self.pid_file             = "#{self.app_root}/log/searchd.#{environment}.pid"
      self.searchd_file_path    = "#{self.app_root}/db/sphinx/#{environment}"
      self.address              = "0.0.0.0"
      self.port                 = 3312
      self.allow_star           = false
      self.min_prefix_len       = 0
      self.min_infix_len        = 0
      self.mem_limit            = "64M"
      self.max_matches          = 1000
      self.morphology           = "stem_en"
      self.charset_type         = "utf-8"
      self.charset_table        = nil
      self.ignore_chars         = nil
      self.html_strip           = false
      self.html_remove_elements = ""
      
      parse_config
    end
    
    def self.environment
      @@environment ||= (
        defined?(Merb) ? ENV['MERB_ENV'] : ENV['RAILS_ENV']
      ) || "development"
    end
    
    def environment
      self.class.environment
    end
    
    # Generate the config file for Sphinx by using all the settings defined and
    # looping through all the models with indexes to build the relevant
    # indexer and searchd configuration, and sources and indexes details.
    #
    def build(file_path=nil)
      load_models
      file_path ||= "#{self.config_file}"
      database_confs = YAML::load(ERB.new(IO.read("#{app_root}/config/database.yml")).result)
      database_confs.symbolize_keys!
      database_conf  = database_confs[environment.to_sym]
      database_conf.symbolize_keys!
      
      open(file_path, "w") do |file|
        file.write <<-CONFIG
indexer
{
  mem_limit = #{self.mem_limit}
}

searchd
{
  address = #{self.address}
  port = #{self.port}
  log = #{self.searchd_log_file}
  query_log = #{self.query_log_file}
  read_timeout = 5
  max_children = 30
  pid_file = #{self.pid_file}
  max_matches = #{self.max_matches}
}
        CONFIG
        
        ThinkingSphinx.indexed_models.each do |model|
          model           = model.constantize
          sources         = []
          delta_sources   = []
          prefixed_fields = []
          infixed_fields  = []
          
          model.indexes.each_with_index do |index, i|
            file.write index.to_config(i, database_conf, charset_type)
            
            create_array_accum if index.adapter == :postgres
            sources << "#{model.indexes.first.name}_#{i}_core"
            delta_sources << "#{model.indexes.first.name}_#{i}_delta" if index.delta?
          end
          
          source_list = sources.collect { |s| "source = #{s}" }.join("\n")
          delta_list  = delta_sources.collect { |s| "source = #{s}" }.join("\n")
          
          file.write core_index_for_model(model, source_list)
          unless delta_list.blank?
            file.write delta_index_for_model(model, delta_list)
          end
          
          file.write distributed_index_for_model(model)
        end
      end
    end
    
    # Make sure all models are loaded - without reloading any that
    # ActiveRecord::Base is already aware of (otherwise we start to hit some
    # messy dependencies issues).
    # 
    def load_models
      base = "#{app_root}/app/models/"
      Dir["#{base}**/*.rb"].each do |file|
        model_name = file.gsub(/^#{base}([\w_\/\\]+)\.rb/, '\1')
        
        next if model_name.nil?
        next if ::ActiveRecord::Base.send(:subclasses).detect { |model|
          model.name == model_name
        }
        
        begin
          model_name.classify.constantize
        rescue LoadError
          model_name.gsub!(/.*[\/\\]/, '')
          retry
        rescue NameError
          next
        end
      end
    end
    
    private
    
    # Parse the config/sphinx.yml file - if it exists - then use the attribute
    # accessors to set the appropriate values. Nothing too clever.
    # 
    def parse_config
      path = "#{app_root}/config/sphinx.yml"
      return unless File.exists?(path)
      
      conf = YAML::load(ERB.new(IO.read(path)).result)[environment]
      
      conf.each do |key,value|
        self.send("#{key}=", value) if self.methods.include?("#{key}=")
      end unless conf.nil?
    end
    
    def core_index_for_model(model, sources)
      output = <<-INDEX

index #{model.indexes.first.name}_core
{
#{sources}
path = #{self.searchd_file_path}/#{model.indexes.first.name}_core
charset_type = #{self.charset_type}
INDEX
      
      morphology  = model.indexes.inject(self.morphology) { |morph, index|
        index.options[:morphology] || morph
      }
      output += "  morphology     = #{morphology}\n"         unless morphology.blank?
      output += "  charset_table  = #{self.charset_table}\n" unless self.charset_table.nil?
      output += "  ignore_chars   = #{self.ignore_chars}\n"  unless self.ignore_chars.nil?
      
      output += "  min_prefix_len = #{self.min_prefix_len}\n" if self.min_prefix_len > 0
      output += "  min_infix_len  = #{self.min_infix_len}\n"  if self.min_infix_len > 0
      output += "  enable_star    = 1\n"                      if self.allow_star
      
      output += "  html_strip     = 1\n" if self.html_strip
      output += "  html_remove_elements = #{self.html_remove_elements}\n" unless self.html_remove_elements.blank?

      unless model.indexes.collect(&:prefix_fields).flatten.empty?
        output += "  prefix_fields = #{model.indexes.collect(&:prefix_fields).flatten.join(', ')}\n"
      end
      
      unless model.indexes.collect(&:infix_fields).flatten.empty?
        output += "  infix_fields  = #{model.indexes.collect(&:infix_fields).flatten.join(', ')}\n"
      end
      
      output + "}\n"
    end
    
    def delta_index_for_model(model, sources)
      <<-INDEX
index #{model.indexes.first.name}_delta : #{model.indexes.first.name}_core
{
  #{sources}
  path = #{self.searchd_file_path}/#{model.indexes.first.name}_delta
}
      INDEX
    end
    
    def distributed_index_for_model(model)
      sources = ["local = #{model.indexes.first.name}_core"]
      if model.indexes.any? { |index| index.delta? }
        sources << "local = #{model.indexes.first.name}_delta"
      end
      
      <<-INDEX
index #{model.indexes.first.name}
{
  type = distributed
  #{ sources.join("\n  ") }
  charset_type = #{self.charset_type}
}
      INDEX
    end
    
    def create_array_accum
      ::ActiveRecord::Base.connection.execute "begin"
      ::ActiveRecord::Base.connection.execute "savepoint ts"
      begin
        ::ActiveRecord::Base.connection.execute <<-SQL
          CREATE AGGREGATE array_accum (anyelement)
          (
              sfunc = array_append,
              stype = anyarray,
              initcond = '{}'
          );
        SQL
      rescue
        raise unless $!.to_s =~ /already exists with same argument types/
        ::ActiveRecord::Base.connection.execute "rollback to savepoint ts"
      end
      ::ActiveRecord::Base.connection.execute "release savepoint ts"
      ::ActiveRecord::Base.connection.execute "commit"
    end
  end
end
