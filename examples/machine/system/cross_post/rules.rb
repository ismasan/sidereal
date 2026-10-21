# frozen_string_literal: true

module CrossPost
  # What each service accepts in a post. Post::Targets checks a draft against
  # the rules of every service it's going to: a draft can only be submitted
  # once it's valid for all of them.
  Rules = Data.define(:service, :max_chars, :max_media, :max_videos, :requires_text, :requires_alt_text) do
    def errors(text:, media:)
      [
        ('text is required' if requires_text && text.strip.empty?),
        ('nothing to post' if text.strip.empty? && media.empty?),
        ("longer than #{max_chars} characters" if text.length > max_chars),
        ("more than #{max_media} attachments" if media.size > max_media),
        ("more than #{max_videos} video" if media.count { it.kind == 'video' } > max_videos),
        ('every image needs alt text' if requires_alt_text && media.any? { it.alt.to_s.empty? })
      ].compact
    end

    def valid?(**) = errors(**).empty?
  end

  class Rules
    ALL = {
      'x' => new(service: 'x', max_chars: 280, max_media: 4, max_videos: 1, requires_text: false, requires_alt_text: false),
      'bluesky' => new(service: 'bluesky', max_chars: 300, max_media: 4, max_videos: 1, requires_text: false, requires_alt_text: false),
      'linkedin' => new(service: 'linkedin', max_chars: 3000, max_media: 9, max_videos: 1, requires_text: true, requires_alt_text: false),
      'mastodon' => new(service: 'mastodon', max_chars: 500, max_media: 4, max_videos: 1, requires_text: false, requires_alt_text: true)
    }.freeze

    def self.fetch(service) = ALL.fetch(service)
  end
end
