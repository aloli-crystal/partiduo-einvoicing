# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :test do |config|
  # Base de test propre à chaque agent ou job : DATABASE_URL (le nom doit
  # contenir « test » ; défaut postgres:///partiduo_test?host=/tmp). Elle est
  # vidée et reconstruite par les migrations à chaque exécution des specs.
  config.database do |db|
    db.from_url(Partiduo::Config.database_url)
  end
  config.media_files.root = File.join(Dir.tempdir, "partiduo-einvoicing-media-#{Process.pid}")
end
