class App < ActiveRecord::Base
  include ActiveModel::Dirty
  include ActAsTimeAsBoolean
  include HTTParty

  http_proxy *ENV['PROXY'].split(':') if ENV['PROXY']

  APP_FIELDS = %w( dynos workers repo_size slug_size stack requested_stack create_status repo_migrate_status owner_delinquent owner_email owner_name web_url git_url buildpack_provided_description tier region )

  PROCESS_FIELDS = %w( pretty_state process state heroku_type command elapsed transitioned_at release action size )
  PROCESS_FIELDS_PREFIXED = %w( type )

  has_many :processes, primary_key: 'name', foreign_key: 'app_name', class_name: HerokuProcess, dependent: :destroy

  time_as_boolean :ping_disabled, opposite: :ping_enabled

  scope :not_updated_since, ->(since) { where 'updated_at < ?', since }
  scope :not_in_maintenance, -> { where( maintenance: false ) }
  scope :in_maintenance, -> { where( maintenance: true ) }
  scope :pingable, -> { ping_enabled.not_in_maintenance }

  after_save :update_maintenance

  def update_maintenance
    return if maintenance_was.nil? || !maintenance_changed?

    he = Heroku::API.new
    he.post_app_maintenance name, (maintenance ? 1 : 0)
  rescue Heroku::API::Errors::RateLimitExceeded => e
    logger.error 'Rate limit exceed !'
  end

  def self.retrieve_from_heroku
    he = Heroku::API.new
    me = he.get_user.body['email']
    heroku_apps = he.get_apps.body
    start_retrieving_at = Time.current

    heroku_apps.each do |heroku_app|
      next unless heroku_app['owner_email'] == me

      app = App.find_or_create_by name: heroku_app['name']
      maintenance = he.get_app_maintenance(app.name).body['maintenance']
      app_attributes = prepare_heroku_app(heroku_app).merge maintenance: maintenance

      app.update_attributes app_attributes
      app.touch
    end

    not_updated_since(start_retrieving_at).destroy_all
  rescue Heroku::API::Errors::RateLimitExceeded
    logger.error 'Rate limit exceed !'
  end

  def self.retrieve_process_from_heroku
    he = Heroku::API.new

    App.not_in_maintenance.each do |app|
      begin
        heroku_processes = he.get_ps(app.name).body

        app.processes = heroku_processes.map do |heroku_process|
          process = HerokuProcess.find_or_create_by heroku_id: heroku_process['id']
          process.update_attributes prepare_heroku_process(heroku_process)

          process
        end
        app.save
      rescue Heroku::API::Errors::NotFound
        # App does not exist anymore. Delete it
        app.destroy
      end
    end
  rescue Heroku::API::Errors::RateLimitExceeded
    logger.error 'Rate limit exceed !'
  end

  def self.ping_apps
    pingable.map do |app|
      begin
        res = HTTParty.head app.web_url, timeout: 30
        app.update_attribute :http_status, res.code
      rescue Timeout::Error => e
        # TODO
      rescue Exception => e
        # TODO
      end
    end
  end

  private

  def self.prepare_heroku_app(app)
    app.reject { |k, _v| !k.in? APP_FIELDS }
  end

  def self.prepare_heroku_process(process)
    process.inject({}){ |option, (k,v)|
      if k.in?(PROCESS_FIELDS_PREFIXED)
        option["heroku_#{k}"] = v
      else
        option[k] = v
      end
      option
    }.reject{ |k, _v| !k.in? PROCESS_FIELDS }
  end
end
