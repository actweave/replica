# Shares suggestions without sharing browser and bearer-token authentication.
module MentionCandidates
  extend ActiveSupport::Concern

  included do
    include HasReviewCommentContext
    before_action { response.headers["Cache-Control"] = "private, no-store" }
  end

  def index
    members = User.external_members_of(@repository).order(:login).map do |user|
      { login: user.login, name: user.name, avatarUrl: user.avatar_url }
    end
    configuration = GithubAppConfiguration.current
    return render json: { candidates: [], externalCandidates: members } if @repository.local? || configuration.nil?

    candidates = Rails.cache.fetch \
      [ "mention-candidates", @repository.cache_key_with_version ],
      expires_in: 1.minute do
      configuration.github_client.repositories.mention_candidates \
        @repository,
        token: configuration.tokens.installation
    end
    render json: { candidates:, externalCandidates: members }
  end
end
