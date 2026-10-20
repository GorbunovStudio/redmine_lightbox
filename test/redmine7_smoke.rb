require 'minitest/autorun'
require 'action_controller/test_case'
require 'base64'
require 'tmpdir'

class Redmine7LightboxTest < ActionController::TestCase
  setup do
    raise 'Run only against the upgraded local db service' unless ActiveRecord::Base.connection_db_config.host == 'db'
    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @routes = Rails.application.routes
    @user = User.active.where(admin: true).first!
    @request.session[:user_id] = @user.id
    @request.session[:tk] = @user.generate_session_token
    User.current = @user
    @issue = Issue.joins(:project).where(projects: {status: Project::STATUS_ACTIVE}).first!
    @storage_path = Attachment.storage_path
    @directory = Dir.mktmpdir('optimus-lightbox-smoke')
    Attachment.storage_path = @directory
    @image = fixture_attachment('optimus-smoke.png', 'image/png', Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDXsAAAAASUVORK5CYII='))
    @pdf = fixture_attachment('optimus-smoke.pdf', 'application/pdf', "%PDF-1.4\n%%EOF\n")
  end

  teardown do
    Attachment.storage_path = @storage_path if @storage_path
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
    @connection.rollback_transaction if @connection
    User.current = nil
    Setting.clear_cache
  end

  private

  def fixture_attachment(filename, content_type, data)
    attributes = {container_type: 'Issue', container_id: @issue.id, author_id: @user.id,
                  filename: filename, disk_filename: filename, disk_directory: '',
                  content_type: content_type, filesize: data.bytesize,
                  digest: Digest::SHA256.hexdigest(data), created_on: Time.current}
    attachment_id = Attachment.insert_all!([attributes], record_timestamps: false, returning: ['id']).rows.first.first
    attachment = Attachment.find(attachment_id)
    File.binwrite(attachment.diskfile, data)
    attachment
  end
end

class Redmine7LightboxIssueTest < Redmine7LightboxTest
  tests IssuesController

  def test_issue_lightbox_assets_and_links
    get :show, params: {id: @issue.id}
    assert_response :success
    assert_select 'script[src*="redmine_lightbox/lightbox-"]', count: 1
    assert_select 'script[src*="redmine_lightbox/glightbox.min-"]', count: 1
    assert_select "a.lightbox.png[href*='/attachments/download/#{@image.id}/']", minimum: 1
    assert_select "a.lightbox.pdf[href*='/attachments/download/#{@pdf.id}/']", minimum: 1
    assert_select "a.icon-download[href*='/attachments/download/#{@image.id}/']", minimum: 1
    assert_select 'a[href*="/attachments/download_inline/"]', count: 0
  end
end

class Redmine7LightboxFilesTest < Redmine7LightboxTest
  tests FilesController

  def test_file_list_keeps_lightbox_and_download_links
    @image.update_columns(container_type: 'Project', container_id: @issue.project_id)
    @pdf.update_columns(container_type: 'Project', container_id: @issue.project_id)
    get :index, params: {project_id: @issue.project.identifier}
    assert_response :success
    assert_select "a.lightbox.png[href*='/attachments/download/#{@image.id}/']", minimum: 1
    assert_select "a.lightbox.pdf[href*='/attachments/download/#{@pdf.id}/']", minimum: 1
    assert_select "a.icon-download[href*='/attachments/download/#{@pdf.id}/']", minimum: 1
  end
end

class Redmine7LightboxAttachmentsTest < Redmine7LightboxTest
  tests AttachmentsController

  def test_native_image_pdf_pages_and_raw_downloads
    get :show, params: {id: @image.id, filename: @image.filename, format: :html}
    assert_response :success
    assert_select "img[src*='/attachments/download/#{@image.id}/']", minimum: 1
    get :show, params: {id: @pdf.id, filename: @pdf.filename, format: :html}
    assert_response :success
    assert_select 'object[type="application/pdf"]', count: 1
    get :download, params: {id: @image.id, filename: @image.filename}
    assert_response :success
    assert_equal 'image/png', @response.media_type
    get :download, params: {id: @pdf.id, filename: @pdf.filename, disposition: 'inline'}
    assert_response :success
    assert_equal 'application/pdf', @response.media_type
    assert_match(/\Ainline/, @response.headers.fetch('Content-Disposition'))
  end
end