# == Schema Information
#
# Table name: users
# Database name: primary
#
#  id                      :integer          not null, primary key
#  avatar_url              :string
#  email                   :string
#  hub_admin               :boolean          default(FALSE), not null
#  identity_kind           :string           not null
#  last_authenticated_at   :datetime         not null
#  login                   :string           not null
#  membership_version      :integer          default(0), not null
#  name                    :string
#  welcome_hidden          :boolean          default(FALSE), not null
#  welcome_sign_in_pending :boolean          default(TRUE), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  github_id               :bigint
#
# Indexes
#
#  index_users_on_email               (email) UNIQUE WHERE email IS NOT NULL
#  index_users_on_github_id           (github_id) UNIQUE
#  index_users_on_one_local_identity  (identity_kind) UNIQUE WHERE identity_kind = 'local'
#
# Check Constraints
#
#  users_identity_kind       ((identity_kind = 'github' AND github_id IS NOT NULL) OR (identity_kind IN ('local', 'external') AND github_id IS NULL))
#  users_login_present       (length(trim(login)) > 0)
#  users_positive_github_id  (github_id IS NULL OR github_id > 0)
#
class User < ApplicationRecord
  class AdmissionDenied < StandardError; end
  class RepositoryAccessDenied < AdmissionDenied; end
  class AdminRoleChangeDenied < StandardError
    attr_reader :reason

    # Gives callers a fixed denial reason without exposing submitted data.
    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  LOCAL_AVATAR_URL = "/local-developer-avatar.svg"

  has_many :user_identities, dependent: :delete_all
  has_many :repository_memberships, dependent: :delete_all
  has_many :sessions, dependent: :delete_all
  has_many :branch_banner_dismissals, dependent: :delete_all
  has_many :prototype_introductions, dependent: :delete_all
  has_many :share_link_creator_revocations, dependent: :delete_all
  has_many :review_comments, dependent: :restrict_with_exception
  has_many :review_comment_reactions, dependent: :restrict_with_exception
  has_many :review_thread_reads, dependent: :restrict_with_exception
  has_many :created_share_links, \
    class_name: "ShareLink",
    foreign_key: :created_by_id,
    inverse_of: :created_by,
    dependent: :restrict_with_exception
  has_many :resolved_review_comments, \
    class_name: "ReviewComment",
    foreign_key: :resolved_by_id,
    inverse_of: :resolved_by,
    dependent: :restrict_with_exception

  scope :non_local, -> { where.not(identity_kind: "local") }
  scope :hub_admins, -> { non_local.where(hub_admin: true) }

  normalizes :email, with: -> { _1.strip.downcase.presence }
  validates :email, uniqueness: true, format: URI::MailTo::EMAIL_REGEXP, allow_nil: true
  validates :identity_kind, inclusion: { in: %w[local github external] }
  before_validation(on: :create) { self.identity_kind ||= github_id ? "github" : "local" }
  validates :github_id, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: true, allow_nil: true
  validate :consistent_identity_kind
  validates :login, presence: true
  validate :identity_is_unchanged, on: :update

  # Identifies the single local developer independently of other providers.
  def local?
    identity_kind == "local"
  end

  # Read through the database even when a caller retains an older User instance.
  def current_membership_version
    self.class.where(id:).pick(:membership_version)
  end

  def external?
    identity_kind == "external"
  end

  def hub_admin?
    !local? && super
  end

  # Claims the first sign-in once across browser sessions without redirecting existing users.
  def consume_welcome_sign_in!
    with_lock do
      return false unless welcome_sign_in_pending?

      update!(welcome_sign_in_pending: false)
      !welcome_hidden?
    end
  end

  # Hides only this person's Welcome link, including after later sign-ins.
  def hide_welcome!
    update!(welcome_hidden: true)
  end

  # Serializes role decisions so stale actors and overlapping removals cannot win. Removing the
  # role of the person who connected Copilot also disconnects Copilot.
  def change_hub_admin!(actor:, browser_session:, operation:)
    self.class.transaction do
      # Rails's SQLite write transaction locks before these live authorization reads.
      live_actor = self.class.hub_admins.find_by(id: actor.id)
      raise AdminRoleChangeDenied, :not_authorized if live_actor.nil?

      live_session = Session.find_by(id: browser_session&.id, user_id: live_actor.id)
      raise AdminRoleChangeDenied, :not_authorized if live_session.nil?
      raise FreshAuthorization::Invalid if !FreshAuthorization.fresh?(live_session)

      reload
      raise AdminRoleChangeDenied, :invalid_target if local?
      raise AdminRoleChangeDenied, :invalid_operation if !operation.in?(%w[designate revoke])

      desired_role = operation == "designate"
      if desired_role && external? && !AuthAllowlistEntry.exists?(email:)
        raise AdminRoleChangeDenied, :invalid_target
      end
      raise AdminRoleChangeDenied, :role_changed if hub_admin? == desired_role
      if !desired_role && self.class.hub_admins.count <= 1
        raise AdminRoleChangeDenied, :last_admin
      end

      update!(hub_admin: desired_role)
      AuthAllowlistEntry.find_by(email:)&.update!(hub_admin: desired_role) if external? && email
      context = (Current.security_audit_context || {}).merge(session_id: live_session.id, target_user_id: id)
      SecurityAuditEvent.record! \
        action: "hub_admin.#{operation}",
        outcome: "succeeded",
        actor: live_actor,
        context: context
      end_copilot_connection!(actor: live_actor, context:) if !desired_role
    end
  end

  class << self
    # Designates a bounded selection atomically with the same live role and Session checks.
    def designate_hub_admins!(actor:, browser_session:, user_ids:)
      validate_hub_admin_selection!(user_ids)

      transaction do
        targets = where(id: user_ids).order(:id).to_a
        raise AdminRoleChangeDenied, :invalid_target if targets.length != user_ids.length

        targets.each do |target|
          target.change_hub_admin!(actor:, browser_session:, operation: "designate")
        end
      end
    end

    # Rejects malformed or oversized role selections before requesting fresh proof.
    def validate_hub_admin_selection!(user_ids)
      if !user_ids.is_a?(Array) || !user_ids.length.in?(1..50) ||
          user_ids.any? { !_1.is_a?(String) || !_1.match?(/\A[1-9]\d{0,17}\z/) } ||
          user_ids.uniq.length != user_ids.length
        raise AdminRoleChangeDenied, :invalid_selection
      end
    end

    # Returns the one developer identity used only in explicit local mode.
    def local_developer!
      raise AdmissionDenied, "Local sign-in is disabled" if !LocalDevelopment.enabled?

      user = find_or_initialize_by(identity_kind: "local")
      user.update! \
        login: "local",
        name: "Local developer",
        avatar_url: LOCAL_AVATAR_URL,
        last_authenticated_at: Time.current
      user
    end

    # Admits readers and enrolled operators without inventing repository access.
    def admit!(profile, accessible_repository_ids:)
      github_id = profile.fetch("id")
      login = profile.fetch("login")
      if !github_id.is_a?(Integer) || !github_id.positive? || !login.is_a?(String) || login.blank?
        raise AdmissionDenied, "GitHub returned an invalid user identity"
      end

      repository_ids = accessible_repository_ids.map(&:to_i)
      admitted = find_by(github_id:)&.hub_admin? || Repository.active.where(github_id: repository_ids).exists?
      raise RepositoryAccessDenied, "No installed repository is available" if !admitted

      save_github_identity!(profile)
    rescue KeyError, TypeError
      raise AdmissionDenied, "GitHub returned an incomplete user identity"
    end

    # Persists a profile already verified by GitHub OAuth, never its token.
    def save_github_identity!(profile)
      github_id = profile.fetch("id")
      login = profile.fetch("login")
      if !github_id.is_a?(Integer) || !github_id.positive? || !login.is_a?(String) || login.blank?
        raise AdmissionDenied, "GitHub returned an invalid user identity"
      end

      user = find_or_initialize_by(github_id:)
      user.update! \
        login:,
        name: profile["name"],
        avatar_url: profile["avatar_url"],
        last_authenticated_at: Time.current
      user
    rescue KeyError, TypeError
      raise AdmissionDenied, "GitHub returned an incomplete user identity"
    end
  end

  private

  # Disconnects Copilot when this person connected it, since they no longer administer Hub.
  def end_copilot_connection!(actor:, context:)
    connection = CopilotConnection.find_by(user_id: id)
    return if connection.nil?

    connection.destroy!
    CopilotConnectionState.advance!
    SecurityAuditEvent.record!(action: "copilot_connection.disconnect", outcome: "succeeded", actor:, context:)
  end

  # Prevents accidentally persisting a local-only account in production.
  def consistent_identity_kind
    errors.add(:github_id, "is required") if identity_kind == "github" && github_id.nil?
    errors.add(:github_id, "must be empty") if identity_kind != "github" && github_id.present?
    errors.add(:identity_kind, "requires local development") if local? && !LocalDevelopment.enabled?
  end

  # Keeps the durable GitHub identity from changing with mutable profile data.
  def identity_is_unchanged
    errors.add(:identity_kind, "cannot change") if will_save_change_to_identity_kind?
    errors.add(:github_id, "cannot change") if will_save_change_to_github_id?
  end
end
