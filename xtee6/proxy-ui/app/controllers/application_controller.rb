require "management_request_helper"

java_import Java::ee.cyber.sdsb.common.SystemProperties
java_import Java::ee.cyber.sdsb.common.conf.globalconf.GlobalConf
java_import Java::ee.cyber.sdsb.common.conf.serverconf.dao.ClientDAOImpl
java_import Java::ee.cyber.sdsb.common.conf.serverconf.dao.IdentifierDAOImpl
java_import Java::ee.cyber.sdsb.common.conf.serverconf.dao.ServerConfDAOImpl
java_import Java::ee.cyber.sdsb.common.conf.serverconf.dao.UiUserDAOImpl
java_import Java::ee.cyber.sdsb.common.conf.serverconf.model.UiUserType
java_import Java::ee.cyber.sdsb.common.conf.serverconf.ServerConfDatabaseCtx
java_import Java::ee.cyber.sdsb.common.identifier.ClientId
java_import Java::ee.cyber.sdsb.common.identifier.SecurityServerId
java_import Java::ee.cyber.sdsb.common.util.CryptoUtils
java_import Java::ee.cyber.sdsb.commonui.SignerProxy

class ApplicationController < BaseController

  SDSB_INSTALLED_FILE = "/usr/xtee/etc/sdsb_installed"
  SDSB_ACTIVATED_FILE = "/usr/xtee/etc/sdsb_activated"
  SDSB_PROMOTED_FILE = "/usr/xtee/etc/sdsb_promoted"

  SDSB_PROMOTED_PRIVILEGES = [
    :add_wsdl,
    :enable_disable_wsdl,
    :refresh_wsdl,
    :delete_wsdl_missing_services,
    :delete_wsdl,
    :edit_service_params,
    :edit_service_acl,
    :import_export_service_acl,
    :edit_subject_open_services,
    :import_export_subject_acl,
    :generate_internal_ssl,
    :add_client_internal_cert,
    :delete_client_internal_cert,
    :edit_client_internal_connection_type,
    :edit_acl_subject_open_services
  ]

  INTERNAL_SSL_CERT_PATH = "/etc/sdsb/ssl/internal.crt"

  include ManagementRequestHelper

  around_filter :transaction

  before_filter :demote_sdsb
  before_filter :check_conf, :except => [:menu, :alerts]
  before_filter :read_locale
  before_filter :read_server_id, :except => [:menu, :alerts]
  before_filter :read_owner_name, :except => [:menu, :alerts]

  helper_method :x55_installed?, :sdsb_activated?, :sdsb_dependent?, :sdsb_promoted?

  def index
    if can?(:view_clients)
      redirect_to :controller => 'clients', :action => 'index'
    else
      redirect_to :controller => 'sysparams', :action => 'index'
    end
  end

  def alerts
    logger.debug("checking for alerts")

    if initialized?
      @alerts = []

      SignerProxy::getTokens.each do |token|
        if token.id == SignerProxy::SSL_TOKEN_ID
          unless token.active
            link = url_for(:controller => :keys, :only_path => true)
            text = t('application.softtoken_pin_not_entered')

            @alerts << {
              :link => "<a href=\"#{link}\">#{text}</a>"
            }
          end
          break
        end
      end
    end

    render :json => {
      :alerts => @alerts
    }
  end

  def set_locale
    unless I18n.available_locales.include?(params[:locale].to_sym)
      raise "invalid locale"
    end

    ui_user = UiUserDAOImpl.getInstance.getUiUser(current_user.name)
    
    unless ui_user
      ui_user = UiUserType.new
      ui_user.username = current_user.name
    end

    ui_user.locale = params[:locale]

    @session.save(ui_user)

    render :nothing => true
  end

  private

  def render(*args)
    if @tx && @tx.isActive && !@tx.wasCommitted
      logger.debug("committing transaction")
      @tx.commit
    end

    if @after_commit && @tx && @tx.wasCommitted
      begin
        logger.debug("executing after_commit actions")
        @after_commit.each do |proc|
          proc.call
        end
      rescue
        @after_commit = []
        raise $!
      end
    end

    # Everything that can fail has been done,
    # now let's do the actual rendering.
    super
  end

  def transaction
    if @tx && @tx.isActive && !@tx.wasCommitted
      yield
      return
    end

    @after_commit = []

    begin
      begin
        logger.debug("beginning transaction")
        @session = ServerConfDatabaseCtx.getSession
        @tx = @session.beginTransaction
      rescue Java::java.lang.Exception
        logger.error(ExceptionUtils.getStackTrace($!))

        raise t('application.database_connection_error')
      end

      yield

      if @tx.isActive && !@tx.wasCommitted
        logger.debug("committing transaction")
        @tx.commit
      end
    rescue Exception, Java::java.lang.Exception
      logger.error("Error while executing in transaction: #{$!.message}")

      begin
        logger.debug("rolling back transaction")
        @tx.rollback
      rescue Exception, Java::java.lang.Exception
        logger.error("Error rolling back transaction: #{$!.message}")
      end

      @tx = nil

      raise $!
    end
  end

  def check_conf
    redirect_to :controller => :init unless initialized?
  end

  def initialized?
    globalconf_initialized? &&
      serverconf_initialized? &&
      software_token_initialized?
  end

  def globalconf_initialized?
    conf_anchor_file = SystemProperties::getConfigurationAnchorFile()
    logger.debug("Checking existence of configuration anchor file "\
        "'#{conf_anchor_file}'")

    File.exists?(conf_anchor_file)
  end

  def serverconf_initialized?
    serverconf &&
      serverconf.owner &&
      serverconf.serverCode
  end

  def after_commit(&block)
    @after_commit << block
  end

  def serverconf
    if !@serverconf && ServerConfDAOImpl.instance.confExists
      @serverconf = ServerConfDAOImpl.instance.conf
    end

    logger.debug("Serverconf is nil? #{@serverconf == nil}")
    @serverconf
  end

  def serverconf_save(serverconf = @serverconf)
    ServerConfDatabaseCtx.session.saveOrUpdate(serverconf)
  end

  def owner_identifier
    @owner_identifier ||= serverconf.owner.identifier
  end

  def sdsb_instance
    GlobalConf::getInstanceIdentifier
  end

  def read_server_id
    return @server_id if @server_id
    return unless serverconf && serverconf.owner

    owner = owner_identifier
    server_code = serverconf.serverCode

    @server_id = SecurityServerId.create(
      owner.sdsbInstance, owner.memberClass,
      owner.memberCode, server_code)
  end

  def read_owner_name
    return @owner_name if @owner_name
    return unless serverconf

    id = owner_identifier
    @owner_name = get_member_name(id.memberClass, id.memberCode)
  end

  def import_services
    if sdsb_promoted?
      logger.info("SDSB promoted, skipping services import")
      return 
    end

    if importer = SystemProperties::getServiceImporterCommand
      logger.info("Importing services from 5.0 to SDSB")

      output = %x["#{importer}" 2>&1]

      if $?.exitstatus != 0
        logger.error(output)
        error(t('application.services_import_failed'))
      end
    else
      logger.warn("Service importer unspecified, skipping import")
    end
  end

  def export_services(delete_client_id = nil)
    unless sdsb_promoted?
      logger.info("SDSB not promoted, skipping services export")
      return 
    end

    if exporter = SystemProperties::getServiceExporterCommand
      logger.info("Exporting services from SDSB to 5.0")

      if delete_client_id
        if delete_client_id.subsystemCode
          subsystemCode = CryptoUtils.encodeBase64(
              delete_client_id.subsystemCode)
        else
          subsystemCode = ""
        end

        delete = "-delete " + [
          CryptoUtils.encodeBase64(delete_client_id.sdsbInstance),
          CryptoUtils.encodeBase64(delete_client_id.memberClass),
          CryptoUtils.encodeBase64(delete_client_id.memberCode),
          subsystemCode
        ].join(',')
      end

      output = %x["#{exporter}" "#{delete}" 2>&1]

      if $?.exitstatus != 0
        logger.error(output)
        error(t('application.services_export_failed'))
      end
    else
      logger.warn("Service exporter unspecified, skipping")
    end
  end

  def export_internal_ssl
    unless sdsb_promoted?
      logger.info("SDSB not promoted, skipping SSL key export")
      return
    end

    if exporter = SystemProperties::getInternalSslExporterCommand
      output = %x["#{exporter}" 2>&1]

      if $?.exitstatus != 0
        logger.error(output)
        error(t('application.internal_ssl_export_failed'))
      end
    else
      logger.warn("Internal SSL exporter unspecified, skipping")
    end
  end

  def restart_service(name)
    output = %x[sudo restart #{name} 2>&1]

    if $?.exitstatus != 0
      error(t('application.restart_service_failed',
              :name => name, :output => output))
    end
  end

  def demote_sdsb
    if sdsb_dependent?
      current_user.privileges -= SDSB_PROMOTED_PRIVILEGES
    end
  end

  def x55_installed?
    @x55_installed ||= File.exists?(SDSB_INSTALLED_FILE)
  end

  def sdsb_activated?
    activated = File.exists?(SDSB_ACTIVATED_FILE)
    logger.debug("SDSB activated = #{activated}")
    activated
  end

  def sdsb_dependent?
    dependent = x55_installed? && !sdsb_promoted?
    logger.debug("SDSB dependent = #{dependent}")
    dependent
  end

  def sdsb_promoted?
    promoted = File.exists?(SDSB_PROMOTED_FILE)
    logger.debug("SDSB promoted = #{promoted}")
    promoted
  end

  def export_cert(cert)
    gz = 'certs.tar.gz'

    Dir.mktmpdir do |dir|
      open("#{dir}/cert.cer", "wb") do |f|
        f.print(cert.to_der)
      end

      open("#{dir}/cert.pem", "wb") do |f|
        f.print(cert.to_pem)
      end

      system("tar -zcvf /tmp/#{gz} --directory=/tmp -C #{dir} .")
    end

    file = File.open("/tmp/#{gz}", 'rb')
    file.read
  end

  def read_internal_ssl_cert
    cert = nil

    if File.exists?(INTERNAL_SSL_CERT_PATH)
      File.open(INTERNAL_SSL_CERT_PATH, 'rb') do |f|
        cert = OpenSSL::X509::Certificate.new(f)
      end
    end

    cert
  end

  def temp_anchor_file
    CommonUi::IOUtils.temp_file(
      "/#{params[:controller]}_anchor_#{request.session_options[:id]}")
  end

  def save_temp_anchor_file(content)
    File.open(temp_anchor_file, 'wb') do |file|
      file.write(content)
    end

    # TODO: add constructor for byte[]
    begin
      anchor = ConfigurationAnchor.new(temp_anchor_file)
    rescue
      log_stacktrace($!)
      raise t("application.invalid_anchor_file")
    end

    hash = CryptoUtils::hexDigest(
      CryptoUtils::SHA224_ID, content.to_java_bytes)
    generated_at = Time.at(anchor.getGeneratedAt.getTime / 1000).utc

    return {
      :hash => hash.upcase.scan(/.{1,2}/).join(':'),
      :generated_at => format_time(generated_at, true)
    }
  end

  def apply_temp_anchor_file
    unless File.exists?(temp_anchor_file)
      raise "Could not find temporary anchor file"
    end

    CommonUi::ScriptUtils.verify_internal_configuration(temp_anchor_file)
    File.rename(temp_anchor_file, SystemProperties::getConfigurationAnchorFile)

    download_configuration
  end

  def download_configuration
    logger.info("Starting globalconf download")

    port = SystemProperties::getConfigurationClientPort() + 1
    uri = URI("http://localhost:#{port}/execute")

    begin
      response = Net::HTTP.get_response(uri)
    rescue
      log_stacktrace($!)
      raise t('application.configuration_download_failed', :response => $!.message)
    end

    if response.code == '500'
      logger.error(response.body)
      raise t('application.configuration_download_failed', :response => response.body)
    end
  end

  def get_identifier(id)
    return nil unless id

    IdentifierDAOImpl.getIdentifier(id) || id
  end

  def get_member_name(member_class, member_code)
    if !member_class.blank? && !member_code.blank?
      return GlobalConf::getMemberName(
        ClientId.create(sdsb_instance, member_class, member_code, nil))
    else
      return nil
    end
  end

  def read_locale
    return unless current_user

    transaction do
      ui_user = UiUserDAOImpl.getInstance.getUiUser(current_user.name)
      I18n.locale = ui_user.locale if ui_user
    end
  end
end