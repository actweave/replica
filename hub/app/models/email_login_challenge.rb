# == Schema Information
#
# Table name: email_login_challenges
# Database name: primary
#
#  id          :integer          not null, primary key
#  attempts    :integer          default(0), not null
#  code_digest :string           default(""), not null
#  consumed_at :datetime
#  email       :string           not null
#  expires_at  :datetime         not null
#  request_ip  :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_email_login_challenges_on_email                 (email) UNIQUE WHERE consumed_at IS NULL
#  index_email_login_challenges_on_email_and_created_at  (email,created_at)
#  index_email_login_challenges_on_expires_at            (expires_at)
#
# One use of an allowlisted mailbox to establish a Hub session.
class EmailLoginChallenge < ApplicationRecord
  MAX_ATTEMPTS = 5
  scope :pending, -> { where(consumed_at: nil) }
  scope :usable, -> { pending.where("expires_at > ?", Time.current).where(attempts: ...MAX_ATTEMPTS) }

  performs :deliver!, queue_as: :default do
    self.enqueue_after_transaction_commit = true
    discard_on ActiveJob::DeserializationError
  end

  # Local filesystem repositories require unified authorization for external accounts.
  def self.enabled?
    return true if LocalDevelopment.unified_auth?
    return false if LocalDevelopment.enabled?

    ENV["REPLICA_AUTH_EMAIL_ENABLED"].in?(%w[1 true]) ||
      (ENV["RESEND_API_KEY"].present? && AuthAllowlistEntry.exists?)
  end

  # Replace the previous challenge before scheduling delivery by record ID.
  def self.request!(email:, request_ip:)
    transaction do
      next unless AuthAllowlistEntry.exists?(email:)

      pending.where(email:).update_all(consumed_at: Time.current)
      create!(email:, request_ip:, expires_at: 10.minutes.from_now).deliver_later!
    end
  end

  # Generate the secret in the worker, outside of serialized job arguments.
  def deliver!
    code = format("%06d", SecureRandom.random_number(1_000_000))
    code_digest = digest(code)
    claimed = self.class.usable.where(id:, code_digest: "").update_all(code_digest:)
    return unless claimed == 1 && AuthAllowlistEntry.exists?(email:) && self.class.enabled?

    begin
      ResendClient.deliver!(email:, code:)
    rescue ResendClient::DeliveryError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      # A retried job may issue a fresh code only while this challenge is still current.
      self.class.pending.where(id:, code_digest:).update_all(code_digest: "")
      raise
    end
  end

  # Run the caller's session issuance in the same transaction as the one-time claim.
  def self.verify(email:, code:)
    transaction do
      entry = AuthAllowlistEntry.find_by(email:)
      challenge = usable.find_by(email:)
      next false unless entry && challenge&.code_digest.present?

      unless challenge.matches_code?(code)
        challenge.increment!(:attempts)
        next false
      end

      challenge.update!(consumed_at: Time.current)
      user = entry.admit_verified_email!
      next false unless user

      yield user
      true
    end
  end

  # Reject malformed input and compare valid codes without data-dependent timing.
  def matches_code?(code)
    /\A[0-9]{6}\z/.match?(code) && ActiveSupport::SecurityUtils.secure_compare(code_digest, digest(code))
  end

  # Bind each digest to its challenge so equal codes leave unrelated stored values.
  def digest(code)
    key = Rails.application.key_generator.generate_key("replica/email-login", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{id}:#{code}")
  end
end
