# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module SpecSupport
    ROOT = File.expand_path("../..", __DIR__)

    # Reconstruit le schéma de la base de test *par les migrations* (cœur,
    # DOCUMENT et extension), comme `partiduo-app` (DECISIONS D-009).
    def self.migrate_fresh! : Nil
      connection = Marten::DB::Connection.default
      name = Marten.settings.databases.first.name.to_s
      unless name.includes?("test")
        raise "Base de test refusée : « #{name} » ne contient pas « test » (voir DATABASE_URL)."
      end

      connection.open do |db|
        db.exec("DROP SCHEMA public CASCADE")
        db.exec("CREATE SCHEMA public")
      end
      Marten::DB::Management::Migrations::Runner.new(connection).execute
      Partiduo::Modules::State.reset_table_cache
    end
  end
end

Spec.before_suite { Einvoicing::SpecSupport.migrate_fresh! }
