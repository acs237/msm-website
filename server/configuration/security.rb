require "securerandom"

class SecurityConfiguration
  def initialize(environment = ENV)
    @environment = environment
  end

  def apply(app)
    app.set :session_secret, session_secret
    app.enable :sessions
    app.set :sessions, session_options

    # Every other Rack::Protection middleware stays on. session_hijacking is
    # dropped because it compares only the User-Agent, which an attacker who
    # has the cookie also has — while a routine browser update changes it and
    # silently empties the session of every logged-in user, with no error to
    # explain the logout. The cost is real and the protection is not.
    app.set :protection, except: :session_hijacking
  end

  def session_secret
    @session_secret ||= if environment["RACK_ENV"] == "production"
      environment.fetch("SESSION_SECRET")
    else
      environment.fetch("SESSION_SECRET") { SecureRandom.hex(64) }
    end
  end

  private

  attr_reader :environment

  def session_options
    {
      key: "msm.session",
      httponly: true,
      same_site: :lax,
      secure: environment["RACK_ENV"] == "production",
    }
  end
end