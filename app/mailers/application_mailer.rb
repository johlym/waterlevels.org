class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "WaterLevels.org <hello@waterlevels.org>")
  layout "mailer"
  helper MailerHelper

  # No Sidekiq process listens to Action Mailer's built-in `mailers` queue.
  # Generic deliver_later (ContactMailer) goes to the always-on default worker.
  # AlertMailer overrides this to :notifications.
  self.deliver_later_queue_name = :default

  # Rails view filename annotations use multi-line HTML comments that some
  # clients (notably iOS Mail) render as a visible "-->". Keep them out of mail.
  around_action :without_view_annotations

  private

  def without_view_annotations
    previous = ActionView::Base.annotate_rendered_view_with_filenames
    ActionView::Base.annotate_rendered_view_with_filenames = false
    yield
  ensure
    ActionView::Base.annotate_rendered_view_with_filenames = previous
  end
end
