module Database
  class Base
    DBCONFIG_BEGIN_FLAG = "__CAPISTRANODB_CONFIG_BEGIN_FLAG__".freeze
    DBCONFIG_END_FLAG = "__CAPISTRANODB_CONFIG_END_FLAG__".freeze

    attr_accessor :config, :output_file

    def initialize(cap_instance)
      @cap = cap_instance
    end

    def mysql?
      @config['adapter'] =~ /^mysql/
    end

    def postgresql?
      %w(postgresql pg postgis chronomodel).include? @config['adapter']
    end

    def credentials
      credential_params = ""
      username = @config['username'] || @config['user']

      if mysql?
        credential_params << " -u #{username} " if username
        credential_params << " -p'#{@config['password']}' " if @config['password']
        credential_params << " -h #{@config['host']} " if @config['host']
        credential_params << " -S #{@config['socket']} " if @config['socket']
        credential_params << " -P #{@config['port']} " if @config['port']
      elsif postgresql?
        credential_params << " -U #{username} " if username
        credential_params << " -h #{@config['host']} " if @config['host']
        credential_params << " -p #{@config['port']} " if @config['port']
      end

      credential_params
    end

    def database
      @config['database']
    end

    def current_time
      Time.now.strftime("%Y-%m-%d-%H%M%S")
    end

    def output_file
      @output_file ||= "#{database}_#{current_time}.sql.#{compressor.file_extension}"
    end

    def compressor
      @compressor ||= begin
        compressor_klass = @cap.fetch(:compressor).to_s.split('_').collect(&:capitalize).join
        klass = Object.module_eval("::Compressors::#{compressor_klass}", __FILE__, __LINE__)
        klass
      end
    end

    private

    def pgpass
      @config['password'] ? "PGPASSWORD='#{@config['password']}'" : ""
    end

    def dump_cmd
      if mysql?
        "mysqldump #{credentials} #{database} #{dump_cmd_opts}"
      elsif postgresql?
        "#{pgpass} pg_dump #{credentials} #{database} #{dump_cmd_opts}"
      end
    end

    def import_cmd(file)
      if mysql?
        "mysql #{credentials} -D #{database} < #{file}"
      elsif postgresql?
        terminate_connection_sql = "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '#{database}' AND pid <> pg_backend_pid();"
        "#{pgpass} psql -c \"#{terminate_connection_sql};\" #{credentials} #{database}; #{pgpass} dropdb #{credentials} #{database}; #{pgpass} createdb #{credentials} #{database}; #{pgpass} psql #{credentials} -d #{database} < #{file}"
      end
    end

    def dump_cmd_opts
      if mysql?
        "--lock-tables=false --set-gtid-purged=OFF #{dump_cmd_ignore_tables_opts} #{dump_cmd_ignore_data_tables_opts}"
      elsif postgresql?
        "--no-acl --no-owner #{dump_cmd_ignore_tables_opts} #{dump_cmd_ignore_data_tables_opts}"
      end
    end

    def dump_cmd_ignore_tables_opts
      ignore_tables = @cap.fetch(:db_ignore_tables, [])
      if mysql?
        ignore_tables.map { |t| "--ignore-table=#{database}.#{t}" }.join(" ")
      elsif postgresql?
        ignore_tables.map { |t| "--exclude-table=#{t}" }.join(" ")
      end
    end

    def dump_cmd_ignore_data_tables_opts
      ignore_tables = @cap.fetch(:db_ignore_data_tables, [])
      ignore_tables.map { |t| "--exclude-table-data=#{t}" }.join(" ") if postgresql?
    end
  end

  class Remote < Base
    def initialize(cap_instance)
      super(cap_instance)
      puts "Loading remote database config"
      @cap.within @cap.current_path do
        @cap.with rails_env: @cap.fetch(:rails_env) do
          run_string = "runner \"puts '#{DBCONFIG_BEGIN_FLAG}' + ActiveRecord::Base.connection.instance_variable_get(:@config).to_yaml + '#{DBCONFIG_END_FLAG}'\""
          dirty_config_content =
            if @cap.capture(:ruby, "bin/rails -v", '2>/dev/null').size > 0
              @cap.capture(:ruby, "bin/rails #{run_string}", '2>/dev/null')
            else
              @cap.capture(:rails, run_string, '2>/dev/null')
            end
          # Remove all warnings, errors and artefacts produced by bunlder, rails and other useful tools
          config_content = dirty_config_content.match(/#{DBCONFIG_BEGIN_FLAG}(.*?)#{DBCONFIG_END_FLAG}/m)[1]
          @config = YAML.load(config_content, aliases: true).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        end
      end
    end

    def dump
      @cap.execute "cd #{@cap.current_path} && #{dump_cmd} | #{compressor.compress('-', db_dump_file_path)}"
      self
    end

    def download(local_file = "#{output_file}")
      @cap.within @cap.current_path do
        @cap.download! db_dump_file_path, local_file
      end
    end

    def clean_dump_if_needed
      if @cap.fetch(:db_remote_clean)
        @cap.execute "rm -f #{db_dump_file_path}"
      else
        puts "leaving #{db_dump_file_path} on the server (add \"set :db_remote_clean, true\" to deploy.rb to remove)"
      end
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, ".#{compressor.file_extension}"))
      # @cap.run "cd #{@cap.current_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.rails_env} bundle exec rake db:drop db:create && #{import_cmd(unzip_file)}"
      @cap.execute "cd #{@cap.current_path} && #{compressor.decompress(file)} && RAILS_ENV=#{@cap.fetch(:rails_env)} && #{import_cmd(unzip_file)}"
      @cap.execute("cd #{@cap.current_path} && rm #{unzip_file}") if cleanup
    end

    private

    def db_dump_file_path
      "#{db_dump_dir}/#{output_file}"
    end

    def db_dump_dir
      @cap.fetch(:db_dump_dir) || "#{@cap.current_path}/db"
    end
  end

  class Local < Base
    def initialize(cap_instance)
      super(cap_instance)
      puts "Loading local database config"
      dir_with_escaped_spaces = Dir.pwd.gsub ' ', '\ '
      command = "#{dir_with_escaped_spaces}/bin/rails runner \"puts '#{DBCONFIG_BEGIN_FLAG}' + Rails.application.config.database_configuration[Rails.env].to_yaml + '#{DBCONFIG_END_FLAG}'\""
      stdout, status = Open3.capture2(command)
      raise "Error running command (status=#{status}): #{command}" if status != 0

      config_content = stdout.match(/#{DBCONFIG_BEGIN_FLAG}(.*?)#{DBCONFIG_END_FLAG}/m)[1]
      config_hash = YAML.load(config_content, aliases: true).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      @config = fetch(:db_config_key) ? config_hash[fetch(:db_config_key).to_s] : config_hash
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, ".#{compressor.file_extension}"))

      recreate_db_cmd = "DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rake db:drop && bundle exec rake db:create"
      cmd = "#{compressor.decompress(file)} && #{recreate_db_cmd} && #{import_cmd(unzip_file)}"
      puts "executing local: #{cmd}"
      execute(cmd)

      if cleanup
        puts "removing #{unzip_file}"
        File.unlink(unzip_file)
      else
        puts "leaving #{unzip_file} (specify :db_local_clean in deploy.rb to remove)"
      end
      puts "Completed database import"
    end

    def dump
      execute "#{dump_cmd} | #{compressor.compress('-', output_file)}"
      self
    end

    def upload
      remote_file = "#{@cap.current_path}/#{output_file}"
      @cap.within @cap.current_path do
        @cap.upload! output_file, remote_file
      end
    end

    private

    def execute(cmd)
      result = system cmd
      @cap.error "Failed to execute the local command: #{cmd}" unless result
      result
    end
  end

  class << self
    def check(local_db, remote_db = nil)
      return if mysql_db_valid?(local_db, remote_db)
      return if postgresql_db_valid?(local_db, remote_db)

      raise 'Only mysql or postgresql on remote and local server is supported'
    end

    def mysql_db_valid?(local_db, remote_db)
      local_db.mysql? && (remote_db.nil? || remote_db && remote_db.mysql?)
    end

    def postgresql_db_valid?(local_db, remote_db)
      local_db.postgresql? &&
        (remote_db.nil? || (remote_db && remote_db.postgresql?))
    end

    def remote_to_local(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      begin
        remote_db.dump.download
      rescue Exception => e
        puts "E[#{e.class}]: #{e.message}"
      ensure
        remote_db.clean_dump_if_needed
      end
      local_db.load(remote_db.output_file, instance.fetch(:db_local_clean))
    end

    def local_to_remote(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      local_db.dump.upload
      remote_db.load(local_db.output_file, instance.fetch(:db_local_clean))
      File.unlink(local_db.output_file) if instance.fetch(:db_local_clean)
    end

    def local_to_local(instance, dump_file)
      local_db = Database::Local.new(instance)

      check(local_db)

      local_db.load(dump_file, instance.fetch(:db_local_clean))
    end
  end
end
