# frozen_string_literal: true

require "spec_helper"
require "open3"

describe "Rails smoke test" do
  def run_ruby(code, env: {}, chdir: nil)
    command = "bundle exec ruby -e '#{code}'"

    output, err, status = Open3.capture3(
      env,
      command,
      chdir: chdir || File.expand_path("../..", __FILE__)
    )

    if ENV["COMMAND_DEBUG"]
      puts "\n\nCOMMAND:\n#{command}\n\nOUTPUT:\n#{output}\nERROR:\n#{err}\n"
    end

    expect(status).to be_success, "Code failed with: #{output}, err: #{err}"
    warn output if output.match?(/warning:/i)
    output
  end

  context "loaders precendence" do
    before do
      File.write(File.expand_path("../dummy/config/secrets.ejson", __dir__), <<~JSON
        {
          "_public_key": "some-stuff",
          "cool": {
            "port": 2323,
            "user": {
              "port": 1922,
              "password": "e-pass",
              "dob": "2007-07-20"
            }
          }
        }
      JSON
      )
    end

    after do
      File.delete(File.expand_path("../dummy/config/secrets.ejson", __dir__))
    end

    it "loads env after all other loaders", :aggregate_failures do
      output = run_ruby <<~SRC
        # Update path to use our custom ejson
        ENV["PATH"] = "#{File.expand_path("../dummy/bin", __dir__)}#{File::PATH_SEPARATOR}\#{ENV["PATH"]}"

        require "webmock"

        # Provided env
        ENV["COOL_USER__PASSWORD"] = "wepass"

        # Doppler stub
        ENV["DOPPLER_TOKEN"] = "test-token"

        WebMock.enable!
        WebMock::API.stub_request(:get, "https://api.doppler.com/v3/configs/config/secrets/download")
          .with(headers: {"Authorization" => "Bearer test-token"})
          .to_return(status: 200, body: {"COOL_PORT" => "5421", "COOL_USER__PASSWORD" => "pss"}.to_json)

        require "#{File.expand_path("../dummy/config/environment", __dir__)}"

        class CoolConfig < ApplicationConfig
          attr_config :meta,
            :data,
            port: 8080,
            host: "localhost",
            user: {name: "admin", password: "admin"}

          coerce_types host: :string, user: {dob: :date}
        end

        pp CoolConfig.instance

        puts %(user.password = "\#{CoolConfig.instance.user[:password]}")
        puts %(user.name = "\#{CoolConfig.instance.user[:name]}")
        puts "port = \#{CoolConfig.instance.port}"
        puts %(host = "\#{CoolConfig.instance.host}")
        puts %(user.year = \#{CoolConfig.instance.user[:dob].year})
      SRC

      expect(output).to include(%(user.password = "wepass")) # ENV wins everyone
      expect(output).to include(%(user.name = "secret man")) # creds win YAML
      expect(output).to include(%(port = 5421)) # Doppler wins ejson
      expect(output).to include(%(host = "test.host")) # YAML
      expect(output).to include(%(user.year = 2007)) # ejson
    end
  end
end
