module EmberCLI
  class Runner
    TRUE_PROC = ->(*){ true }

    attr_reader :app, :env

    def initialize(app, env)
      @app = app
      @env = env
    end

    def process
      return if skip?

      if EmberCLI.env.development?
        start_or_restart!
      else
        compile!
      end

      wait!
    end

    private

    def path
      env["PATH_INFO"].to_s
    end

    def skip?
      configuration_proc = app.options.fetch(:enable, TRUE_PROC)
      block_arguments = [configuration_proc.arity, 0].max
      arguments = [path, env].first(block_arguments)

      !configuration_proc.call(*arguments)
    end

    def start_or_restart!
      run! unless app.pid && still_running?
    end

    def still_running?
      Process.getpgid app.pid
      true
    rescue Errno::ESRCH # no such process
      false
    end

    def wait!
      app.wait
    end

    def compile!
      app.compile
    end

    def run!
      app.run
    end
  end
end
