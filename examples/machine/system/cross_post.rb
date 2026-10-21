# frozen_string_literal: true

# A cross-posting app, described as a tree of Sourced::Machines: every
# command a user (or a service, or a timer) can send, and the states in which
# each one is accepted. Nothing talks to a real service or keeps a database:
# the machines are the app's specification, to inspect and diagram.
#
#   Account                         sign up, verify, log in, suspend, close
#   ├ Account::Verifying  (part: verifying)
#   ├ Account::Active        (part: active)
#   ├ Session                       (child: one per login)
#   ├ Connections::X                (child: one per connected service,
#   │ ├ X::Authorizing                 each with its own auth handshake part)
#   ├ Connections::Bluesky …
#   └ Post                          (child: one per post)
#     ├ Post::Targets::X …          (regions of drafting: selection and validation per service)
#     └ Post::Deliveries::X …       (regions of publishing: one delivery per service)
module CrossPost
  SERVICES = %w[x bluesky linkedin mastodon].freeze

  # Every machine in the tree, depth first from the root. Parts are drawn
  # inside the machines they're part of, so only the root and its children
  # are listed.
  def self.machines = [Account, *Account.tree.children]
end
