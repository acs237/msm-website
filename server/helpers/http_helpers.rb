require "json"

module HttpHelpers
  # Halts with a 401 unless somebody is logged in. This has to be enforced on
  # the server, not just hidden in the client: the download route takes a file
  # id, so anyone holding one could fetch the file regardless of what the page
  # chooses to render.
  def require_login!
    return true if session[:user_id]

    halt 401, { "Content-Type" => "application/json" },
      { error: "login_required", message: "Log in to access resources" }.to_json
  end

  def request_json
    JSON.parse(request.body.read)
  end

  def json_response(payload, response_status = 200)
    content_type :json
    status response_status
    payload.to_json
  end

  def user_response(user)
    { user: { id: user["id"].to_i, name: user["name"], email: user["email"] } }
  end
end
