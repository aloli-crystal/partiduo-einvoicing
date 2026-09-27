# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Adaptateurs de plateforme agréée et raccordement du dossier (ADR-004 D2,
  # D6). Les adaptateurs s'enregistrent ici : `AFNOR` (XP Z12-013) et
  # `NOALYSS_PEPPOL` dans ce dépôt ; une extension `partiduo-<pa>` (SuperPDP,
  # ADR-004 D8) ajoute le sien par `Einvoicing::Connections.register`.
  # Interne ; les écrans passent par `Einvoicing::Api`.
  module Connections
    alias FieldError = Partiduo::Api::FieldError

    # Paramètre d'un adaptateur : nom, secret (chiffré en base, jamais
    # réaffiché), obligatoire, nature (`url` HTTPS, `text`, `choice`).
    record Field,
      name : String,
      secret : Bool = false,
      required : Bool = true,
      kind : String = "text",
      choices : Array(String) = [] of String

    # Adaptateur : code, clé du libellé, régimes admis (`fr`, `be`),
    # paramètres, constructeur du connecteur.
    record Adapter,
      code : String,
      label_key : String,
      regimes : Array(String),
      fields : Array(Field),
      factory : Proc(Settings, Connector)

    # Paramètres d'un raccordement tels que l'adaptateur les lit, et accès à
    # ses jetons (chiffrés en base).
    class Settings
      getter adapter : String
      getter values : Hash(String, String)
      getter secrets : Hash(String, String)
      getter connection_id : Int64?

      def initialize(@adapter, @values, @secrets, @connection_id = nil)
      end

      def [](name : String) : String
        values[name]? || secrets[name]? || ""
      end

      # Jeton d'accès en cours, s'il est encore valable dans `margin`.
      def access_token(margin : Time::Span = 60.seconds) : String?
        row = connection
        return if row.nil?
        expires = row.access_token_expires_at
        token = row.access_token.to_s
        return if token.empty? || (expires && expires - margin < Time.utc)
        Secrets.decrypt(token)
      rescue Secrets::Error
        nil
      end

      def refresh_token : String?
        connection.try { |row| Secrets.decrypt(row.refresh_token.to_s).presence }
      rescue Secrets::Error
        nil
      end

      # Enregistre les jetons, chiffrés ; `refresh` à `nil` garde le jeton de
      # rafraîchissement en place (rotation : le nouveau remplace l'ancien).
      def store_tokens(access : String, expires_at : Time?, refresh : String? = nil) : Nil
        id = connection_id
        return if id.nil?
        Connection.filter(id: id).update(access_token: Secrets.encrypt(access), access_token_expires_at: expires_at)
        Connection.filter(id: id).update(refresh_token: Secrets.encrypt(refresh)) if refresh
      end

      def clear_tokens : Nil
        connection_id.try { |id| Connection.filter(id: id).update(access_token: "", access_token_expires_at: nil) }
      end

      private def connection : Connection?
        connection_id.try { |id| Connection.filter(id: id).first }
      end
    end

    class NotConfigured < ConnectorError
      def initialize
        super("aucune plateforme agréée raccordée")
      end
    end

    @@adapters = {} of String => Adapter

    def self.register(adapter : Adapter) : Nil
      @@adapters[adapter.code] = adapter
    end

    def self.adapters : Array(Adapter)
      @@adapters.values
    end

    def self.adapter?(code : String) : Adapter?
      @@adapters[code]?
    end

    def self.active : Connection?
      Connection.filter(active: true).first
    end

    def self.settings_of(connection : Connection) : Settings
      values = connection.settings.try(&.as_h?).try(&.transform_values { |value| value.as_s? || value.to_s }) ||
               {} of String => String
      Settings.new(connection.adapter.to_s, values, Secrets.decrypt_json(connection.secrets.to_s),
        connection.id.try(&.to_i64))
    end

    # Connecteur du raccordement actif ; lève `NotConfigured` s'il n'y en a
    # pas ou si son adaptateur n'est plus compilé dans la distribution.
    def self.connector(connection : Connection? = active) : Connector
      raise NotConfigured.new if connection.nil?
      adapter = @@adapters[connection.adapter.to_s]? || raise NotConfigured.new
      adapter.factory.call(settings_of(connection))
    end

    # Contrôle des paramètres saisis pour `adapter` : champs obligatoires
    # (un secret déjà enregistré peut rester vide), adresses HTTPS, choix
    # admis, régime du dossier.
    def self.check(adapter : Adapter?, code : String, values : Hash(String, String), existing : Connection?,
                   regime : String, errors : Array(FieldError)) : Nil
      if adapter.nil?
        errors << FieldError.new("adapter", "einvoicing.errors.connection.adapter.unknown", {"value" => code})
        return
      end
      unless adapter.regimes.includes?(regime)
        errors << FieldError.new("adapter", "einvoicing.errors.connection.adapter.regime",
          {"adapter" => code, "regime" => regime})
      end
      stored = existing ? Secrets.decrypt_json(existing.secrets.to_s) : {} of String => String
      adapter.fields.each do |field|
        value = values[field.name]?.to_s.strip
        if value.empty?
          next unless field.required
          next if field.secret && !stored[field.name]?.to_s.empty?
          errors << FieldError.new(field.name, "einvoicing.errors.connection.field.blank")
          next
        end
        case field.kind
        when "url"
          uri = URI.parse(value) rescue nil
          if uri.nil? || uri.scheme != "https" || uri.host.to_s.empty?
            errors << FieldError.new(field.name, "einvoicing.errors.connection.field.https", {"value" => value})
          end
        when "choice"
          unless field.choices.includes?(value)
            errors << FieldError.new(field.name, "einvoicing.errors.connection.field.choice", {"value" => value})
          end
        end
        if value.size > 2000
          errors << FieldError.new(field.name, "einvoicing.errors.connection.field.too_long", {"max" => "2000"})
        end
      end
    end
  end
end
