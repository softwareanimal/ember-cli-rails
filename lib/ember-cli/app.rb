require "timeout"
require "ember-cli/html_page"
require "ember-cli/asset_resolver"

module EmberCli
  class App
    ADDON_VERSION = "0.0.13"
    EMBER_CLI_VERSIONS = [ "~> 0.1.5", "~> 0.2.0", "~> 1.13" ]

    class BuildError < StandardError; end

    attr_reader :name, :options, :paths, :pid

    delegate :root, to: :paths

    def initialize(name, **options)
      @name, @options = name.to_s, options
      @paths = PathSet.new(self)
    end

    def compile
      @compiled ||= begin
        prepare
        silence_build{ exec command }
        check_for_build_error!
        copy_index_html_file
        true
      end
    end

    def install_dependencies
      if gemfile_path.exist?
        exec "#{bundler_path} install"
      end

      exec "#{npm_path} prune && #{npm_path} install"

      if bower_path.nil?
        fail <<-FAIL
          Bower is required by EmberCLI

          Install it with:

              $ npm install -g bower
        FAIL
      else
        exec "#{bower_path} prune && #{bower_path} install"
      end
    end

    def run
      prepare
      FileUtils.touch lockfile_path
      cmd = command(watch: true)
      @pid = exec(cmd, method: :spawn)
      Process.detach pid
      copy_index_html_file
      set_on_exit_callback
    end

    def run_tests
      prepare
      exit 1 unless exec("#{ember_path} test")
    end

    def stop
      Process.kill :INT, pid if pid
      @pid = nil
    end

    def index_html(sprockets:, head:, body:)
      asset_resolver = AssetResolver.new(
        app: self,
        sprockets: sprockets,
      )
      html_page = HtmlPage.new(
        asset_resolver: asset_resolver,
        content: index_file.read,
        head: head,
        body: body,
      )

      html_page.render
    end

    def exposed_js_assets
      [vendor_assets, application_assets]
    end
    alias exposed_css_assets exposed_js_assets

    def vendor_assets
      "#{name}/vendor"
    end

    def application_assets
      "#{name}/#{ember_app_name}"
    end

    def wait
      Timeout.timeout(build_timeout) do
        wait_for_build_complete_or_error
      end
    rescue Timeout::Error
      suggested_timeout = build_timeout + 5

      warn <<-MSG.strip_heredoc
        ============================= WARNING! =============================

          Seems like Ember #{name} application takes more than #{build_timeout}
          seconds to compile.

          To prevent race conditions consider adjusting build timeout
          configuration in your ember initializer:

            EmberCLI.configure do |config|
              config.build_timeout = #{suggested_timeout} # in seconds
            end

          Alternatively, you can set build timeout per application like this:

            EmberCLI.configure do |config|
              config.app :#{name}, build_timeout: #{suggested_timeout}
            end

        ============================= WARNING! =============================
      MSG
    end

    def method_missing(method_name, *)
      if path_method = supported_path_method(method_name)
        paths.public_send(path_method)
      else
        super
      end
    end

    def respond_to_missing?(method_name, *)
      if supported_path_method(method_name)
        true
      else
        super
      end
    end

    private

    def set_on_exit_callback
      @on_exit_callback ||= at_exit{ stop }
    end

    def supported_path_method(original)
      path_method = original.to_s[/\A(.+)_path\z/, 1]
      path_method if path_method && paths.respond_to?(path_method)
    end

    def silence_build(&block)
      if ENV.fetch("EMBER_CLI_RAILS_VERBOSE") { EmberCli.env.production? }
        yield
      else
        silence_stream STDOUT, &block
      end
    end

    def build_timeout
      options.fetch(:build_timeout) { EmberCli.configuration.build_timeout }
    end

    def watcher
      options.fetch(:watcher) { EmberCli.configuration.watcher }
    end

    def check_for_build_error!
      raise_build_error! if build_error?
    end

    def reset_build_error!
      build_error_file_path.delete if build_error?
    end

    def build_error?
      build_error_file_path.exist?
    end

    def raise_build_error!
      error = BuildError.new("EmberCLI app #{name.inspect} has failed to build")
      error.set_backtrace build_error_file_path.read.split(?\n)
      fail error
    end

    def prepare
      @prepared ||= begin
        check_dependencies!
        check_addon!
        check_ember_cli_version!
        reset_build_error!
        symlink_to_assets_root
        add_assets_to_precompile_list
        true
      end
    end

    def check_ember_cli_version!
      version = dev_dependencies.fetch("ember-cli").split(?-).first

      unless Helpers.match_version?(version, EMBER_CLI_VERSIONS)
        fail <<-MSG.strip_heredoc
          EmberCLI Rails require ember-cli NPM package version to be
          #{EMBER_CLI_VERSIONS.last} to work properly (you have #{version}).
          From within your EmberCLI directory please update your package.json
          accordingly and run:

            $ npm install

        MSG
      end
    end

    def check_addon!
      unless addon_present?
        fail <<-MSG.strip_heredoc
          EmberCLI Rails requires your Ember app to have an addon.

          From within your EmberCLI directory please run:

            $ npm install --save-dev ember-cli-rails-addon@#{ADDON_VERSION}

          in your Ember application root: #{root}
        MSG
      end
    end

    def check_dependencies!
      unless node_modules_present?
        fail <<-MSG.strip_heredoc
          EmberCLI app dependencies are not installed. From your Rails application root please run:

            $ bundle exec rake ember:install

          If you do not require Ember at this URL, you can restrict this check using the `enable`
          option in the EmberCLI initializer.
        MSG
      end
    end

    def assets_path
      paths.assets.join(name)
    end

    def copy_index_html_file
      if environment == "production"
        FileUtils.cp(assets_path.join("index.html"), index_file)
      end
    end

    def index_file
      if environment == "production"
        applications_path.join("#{name}.html")
      else
        dist_path.join("index.html")
      end
    end

    def symlink_to_assets_root
      assets_path.make_symlink dist_path.join("assets")
    rescue Errno::EEXIST
      # Sometimes happens when starting multiple Unicorn workers.
      # Ignoring...
    end

    def add_assets_to_precompile_list
      Rails.configuration.assets.precompile << /\A#{name}\//
    end

    def command(watch: false)
      watch_flag = ""

      if watch
        watch_flag = "--watch"

        if watcher
          watch_flag += " --watcher #{watcher}"
        end
      end

      "#{ember_path} build #{watch_flag} --environment #{environment} --output-path #{dist_path} #{log_pipe}"
    end

    def log_pipe
      "| #{tee_path} -a #{log_path}" if tee_path
    end

    def ember_app_name
      @ember_app_name ||= options.fetch(:name){ package_json.fetch(:name) }
    end

    def environment
      EmberCli.env.production? ? "production" : "development"
    end

    def package_json
      @package_json ||=
        JSON.parse(package_json_file_path.read).with_indifferent_access
    end

    def addon_package_json
      @addon_package_json ||=
        JSON.parse(addon_package_json_file_path.read).with_indifferent_access
    end

    def addon_version
      addon_package_json.fetch("version")
    end

    def dev_dependencies
      package_json.fetch("devDependencies", {})
    end

    def addon_present?
      addon_package_json_file_path.exist? &&
        addon_version == ADDON_VERSION
    end

    def node_modules_present?
      node_modules_path.exist?
    end

    def excluded_ember_deps
      Array.wrap(options[:exclude_ember_deps]).join(?,)
    end

    def env_hash
      ENV.to_h.tap do |vars|
        vars["RAILS_ENV"] = Rails.env
        vars["DISABLE_FINGERPRINTING"] = "true"
        vars["EXCLUDE_EMBER_ASSETS"] = excluded_ember_deps
        vars["BUNDLE_GEMFILE"] = gemfile_path.to_s if gemfile_path.exist?
      end
    end

    def exec(cmd, method: :system)
      Dir.chdir root do
        Kernel.public_send(method, env_hash, cmd)
      end
    end

    def wait_for_build_complete_or_error
      loop do
        check_for_build_error!
        break unless lockfile_path.exist?
        sleep 0.1
      end
    end
  end
end
