class ContactMessage
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :name, :string
  attribute :email, :string
  attribute :subject, :string
  attribute :message, :string
  attribute :turnstile_token, :string
  attribute :remote_ip, :string

  validates :name, :email, :subject, :message, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, length: { maximum: 120 }
  validates :subject, length: { maximum: 200 }
  validates :message, length: { maximum: 5000 }
  validate :turnstile_must_pass

  def deliver
    return false unless valid?

    ContactMailer.with(
      name: name,
      email: email,
      subject: subject,
      message: message
    ).contact_email.deliver_later
    true
  end

  private

  def turnstile_must_pass
    return if TurnstileVerification.new(token: turnstile_token, remote_ip: remote_ip).success?

    errors.add(:base, "Please complete the bot check and try again.")
  end
end
