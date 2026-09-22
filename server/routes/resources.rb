require_relative "../services/resource_proxy"

module Routes
  module Resources
    def self.registered(app)
      app.get "/api/resources" do
        require_login!

        begin
          groups = ResourceProxy.list_groups
          # `items` is the flattened view, kept so a client that ignores
          # grouping keeps working.
          json_response({ groups: groups, items: groups.flat_map { |group| group[:items] } })
        rescue StandardError => error
          warn "Resource list failed (#{error.class}): #{error.message}"
          json_response({ error: "resource_unavailable", message: "Unable to load resources right now" }, 502)
        end
      end

      app.get "/api/resources/download/:file_id" do
        require_login!

        begin
          resource = ResourceProxy.fetch(params[:file_id])
        rescue StandardError => error
          warn "Resource download failed (#{error.class}): #{error.message}"
          halt 502, "Unable to download this resource right now"
        end

        halt 404 unless resource

        content_type resource[:content_type]
        headers["Content-Disposition"] = %(attachment; filename="#{resource[:filename]}")
        # `private`, not `public`: this body is only for the logged-in user who
        # asked for it, and `public` invites shared caches (CDNs, corporate
        # proxies) to store it and hand it to someone who never logged in.
        headers["Cache-Control"] = "private, max-age=3600"
        resource[:body]
      end
    end
  end
end