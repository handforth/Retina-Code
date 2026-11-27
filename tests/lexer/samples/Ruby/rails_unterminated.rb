# Second Ruby sample: Rails-ish model/controller code, DSLs, and an unterminated =begin block at EOF.
# typed: true

class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end

class User < ApplicationRecord
  EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  ROLES = %w[admin editor viewer].freeze
  STATUSES = %i[active suspended deleted].freeze

  has_many :posts, dependent: :destroy, inverse_of: :author
  has_one :profile, -> { where(visible: true) }, class_name: "UserProfile"
  belongs_to :organization, optional: true

  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: EMAIL_REGEX }
  validates :name, length: { in: 2..100 }
  validates :role, inclusion: { in: ROLES, message: "%{value} is not a valid role" }

  before_save :normalize_email
  after_commit -> { Rails.logger.info("user #{id} committed") }, on: %i[create update]

  scope :active, -> { where(status: :active) }
  scope :recent, ->(days = 7) { where("created_at > ?", days.days.ago) }
  scope :search, lambda { |q|
    where("name ILIKE :q OR email ILIKE :q", q: "%#{sanitize_sql_like(q)}%")
  }

  enum :status, { active: 0, suspended: 1, deleted: 2 }, prefix: true

  def full_name = "#{first_name} #{last_name}".strip
  def admin? = role == "admin"

  def as_json(options = {})
    super(options.merge(only: %i[id name email], methods: [:full_name]))
  end

  def self.report
    <<~SQL.squish
      SELECT role, COUNT(*) AS n
      FROM users
      WHERE status = #{statuses[:active]}
      GROUP BY role
    SQL
  end

  private

  def normalize_email
    self.email = email.to_s.downcase.strip.gsub(/\s+/, "")
  end
end

class UsersController < ApplicationController
  before_action :set_user, only: %i[show update destroy]
  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def index
    @users = User.active.search(params[:q].to_s).order(created_at: :desc).page(params[:page]).per(25)
    respond_to do |format|
      format.html
      format.json { render json: @users }
      format.csv { send_data to_csv(@users), filename: "users-#{Date.current.iso8601}.csv" }
    end
  end

  def show
    render json: @user.as_json.merge(posts: @user.posts.count)
  end

  def update
    if @user.update(user_params)
      redirect_to @user, notice: %(User "#{@user.name}" was updated.)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @user.destroy!
    head :no_content
  end

  private

  def set_user = @user = User.find(params.require(:id))

  def user_params
    params.require(:user).permit(:name, :email, :role, tags: [], profile_attributes: %i[bio avatar])
  end

  def not_found(exception)
    render json: { error: exception.message, path: request.path }, status: 404
  end

  def to_csv(users)
    require "csv"
    CSV.generate(headers: true) do |csv|
      csv << %w[id name email]
      users.find_each { |u| csv << [u.id, u.name, u.email] }
    end
  end
end

# Routes DSL
Rails.application.routes.draw do
  root "home#index"
  resources :users, only: %i[index show update destroy] do
    member { post :suspend }
    collection { get :export, defaults: { format: :csv } }
    resources :posts, shallow: true
  end
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      get "status", to: proc { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
    end
  end
  match "*path", to: "errors#not_found", via: :all, constraints: ->(req) { !req.xhr? }
end

# RSpec DSL
RSpec.describe User, type: :model do
  let(:user) { build(:user, email: "  MiXeD@Example.COM ") }
  subject(:saved) { user.tap(&:save!) }

  it { is_expected.to validate_presence_of(:email) }

  it "normalizes email" do
    expect(saved.email).to eq("mixed@example.com")
  end

  context "when the role is invalid" do
    before { user.role = "superuser" }
    it { expect(user).not_to be_valid }
    it "reports the error" do
      user.valid?
      expect(user.errors[:role]).to include(a_string_matching(/superuser is not/))
    end
  end
end

# Odd syntax corners
x = if true then 1 else 2 end
y = begin; Integer("42"); rescue ArgumentError => e; -1; ensure; nil; end
z = [1, 2, 3].sum { |n| n ** 2 } / 2.0
q = defined?(SomeConst) ? :yes : :no
w = !!x && (y || z) and not q
v = x.then { _1 + 1 } => result
u = { "a" => 1 }.transform_keys(&:to_sym)
t = "%05.1f%%" % 12.345
s = "a".."z"
r = (1...10).step(3).to_a
p `echo backtick command #{x}`
puts "done" unless $DEBUG || ENV.fetch("QUIET", nil)

=begin
This embedded document never ends because there is no =end line.
def not_code
  "string inside =begin block"
end
 =end  <- indented, so it does not terminate the block
