# frozen_string_literal: true

# Loads .env before anything reads ENV.
#
# Required from both `falcon.rb` and `boot.rb`, because they run in different
# processes: the Falcon controller loads `falcon.rb` (HOST / PORT / COUNT) and
# never loads the app, while each forked worker loads `boot.rb` via config.ru.
# Requiring `boot.rb` from `falcon.rb` instead would open a SQLite connection
# in the controller, which the fork model deliberately avoids.
#
# The path is resolved against this file, not the working directory, so a rake
# task or console started from elsewhere still finds it. Dotenv never
# overwrites a variable that is already set, so a real environment variable
# beats the file: `PORT=8080 bundle exec falcon host` wins over a PORT in .env.
require 'dotenv'

Dotenv.load(File.expand_path('../.env', __dir__))
