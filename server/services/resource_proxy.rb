require "json"
require "net/http"
require "stringio"
require "uri"
require "googleauth"

class ResourceProxy
  DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.readonly".freeze

  FOLDER_MIME = "application/vnd.google-apps.folder".freeze

  # One level down, not recursive. The configured folder is treated as a parent
  # whose subfolders become groups; a folder with no subfolders still works and
  # yields a single unnamed group, so pointing this at a flat folder behaves as
  # it did before.
  def self.list_groups
    root = ENV["GOOGLE_DRIVE_RESOURCES_FOLDER_ID"].to_s.strip
    raise "GOOGLE_DRIVE_RESOURCES_FOLDER_ID is required" if root.empty?

    subfolders = child_folders(root)
    return [{ name: nil, items: files_in([root]) }] if subfolders.empty?

    # One query across every subfolder plus the root: Drive's `q` takes an OR of
    # parent clauses, so this stays two round trips however many folders there
    # are. Render's free tier is slow enough that per-folder requests show.
    by_parent = files_in([root, *subfolders.map { |f| f["id"] }]).group_by { |file| file[:parentId] }

    groups = subfolders.map { |folder| { name: folder["name"], items: by_parent.fetch(folder["id"], []) } }

    # Files sitting loose in the parent would otherwise vanish silently, which
    # is the same invisible-failure mode this endpoint already had once.
    loose = by_parent.fetch(root, [])
    groups << { name: nil, items: loose } unless loose.empty?

    groups.reject { |group| group[:items].empty? }
  end

  # Kept flat for callers that do not care about grouping.
  def self.list_files
    list_groups.flat_map { |group| group[:items] }
  end

  def self.child_folders(parent_id)
    drive_files(
      q: "'#{parent_id}' in parents and trashed = false and mimeType = '#{FOLDER_MIME}'",
      fields: "nextPageToken,files(id,name)",
    )
  end

  def self.files_in(parent_ids)
    parents = parent_ids.map { |id| "'#{id}' in parents" }.join(" or ")

    drive_files(
      q: "(#{parents}) and trashed = false and mimeType != '#{FOLDER_MIME}'",
      fields: "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink,parents)",
    ).map do |file|
      {
        id: file["id"],
        name: file["name"],
        mimeType: file["mimeType"],
        size: file["size"].to_i,
        modifiedTime: file["modifiedTime"],
        webViewLink: file["webViewLink"],
        parentId: Array(file["parents"]).first,
      }
    end
  end

  # Drive caps a page at 1000 and silently truncates if the token is ignored.
  def self.drive_files(query)
    files = []
    page_token = nil

    loop do
      uri = URI("https://www.googleapis.com/drive/v3/files")
      uri.query = URI.encode_www_form(
        **query,
        orderBy: "name",
        pageSize: "1000",
        includeItemsFromAllDrives: "true",
        supportsAllDrives: "true",
        **(page_token ? { pageToken: page_token } : {}),
      )

      response = drive_request(uri)
      raise "Google Drive API returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      files.concat(payload.fetch("files", []))
      page_token = payload["nextPageToken"]
      break if page_token.nil? || page_token.empty?
    end

    files
  end

  def self.fetch(file_id)
    metadata = file_metadata(file_id)
    response = drive_media_response(file_id)
    raise "Google Drive API returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    {
      body: response.body,
      content_type: response["content-type"]&.split(";")&.first || "application/octet-stream",
      filename: sanitize_filename(metadata["name"] || file_id),
    }
  end

  def self.google_service_account_json
    json = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"].to_s.strip
    return JSON.parse(json) unless json.empty?

    path = ENV["GOOGLE_SERVICE_ACCOUNT_KEY_PATH"].to_s.strip
    raise "GOOGLE_SERVICE_ACCOUNT_JSON or GOOGLE_SERVICE_ACCOUNT_KEY_PATH is required" if path.empty?

    JSON.parse(File.read(path))
  end

  def self.google_access_token
    credentials = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(JSON.generate(google_service_account_json)),
      scope: DRIVE_SCOPE,
    )
    credentials.fetch_access_token!
    credentials.access_token
  end

  def self.file_metadata(file_id)
    uri = URI("https://www.googleapis.com/drive/v3/files/#{file_id}")
    uri.query = URI.encode_www_form(
      fields: "name,mimeType",
      supportsAllDrives: "true",
    )

    response = drive_request(uri)
    raise "Google Drive API returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def self.drive_media_response(file_id)
    uri = URI("https://www.googleapis.com/drive/v3/files/#{file_id}?alt=media&supportsAllDrives=true")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{google_access_token}"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60
    http.request(request)
  end

  def self.drive_request(uri)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{google_access_token}"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60
    http.request(request)
  end

  def self.sanitize_filename(name)
    cleaned = name.to_s.gsub(/[\\\/:*?"<>|\r\n]+/, " ").strip
    cleaned.empty? ? "download" : cleaned
  end

  private_class_method :google_service_account_json, :google_access_token, :drive_media_response, :drive_request, :drive_files, :child_folders, :files_in, :file_metadata, :sanitize_filename
end