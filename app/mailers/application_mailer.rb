class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "WaterLevels.org <hello@waterlevels.org>")
  layout "mailer"
  helper MailerHelper

  # No Sidekiq process listens to the default `mailers` queue. Route deliver_later
  # onto notifications_worker (config/sidekiq_notifications.yml) so ContactMailer
  # and AlertMailer are both drained. AlertMailer also sets this explicitly.
  self.deliver_later_queue_name = :notifications

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
