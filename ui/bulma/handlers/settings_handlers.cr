# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Ui
    # Raccordement de la plateforme agréée (`/ext/EINV/settings`) : un seul
    # adaptateur actif (ADR-004 D2), mode bac à sable ou production affiché
    # en permanence (ADR-004 D8), secrets jamais réaffichés.
    class SettingsHandler < Handler
      def get
        show(nil, {} of String => Array(String))
      end

      def post
        adapter = field("adapter")
        known = Api.adapters(current.actor).find { |item| item.code == adapter }
        values = {} of String => String
        known.try &.fields.each { |item| values[item.name] = field(item.name) }
        result = Api.configure(current.actor, Api::ConnectionInput.new(adapter, values))
        if result.success?
          flash["success"] = I18n.t("einvoicing_ui.flash.configured")
          return go(Ui.url("settings"))
        end
        show(adapter, errors_of(result), values, 422)
      end

      def show(selected : String?, errors : Hash(String, Array(String)), values = {} of String => String,
               status : Int32 = 200) : Marten::HTTP::Response
        actor = current.actor
        connection = Api.connection(actor)
        adapters = Api.adapters(actor).select(&.available).map do |adapter|
          fields = adapter.fields.map do |item|
            Ui.row({
              "name"     => item.name,
              "label"    => I18n.t(item.label_key),
              "kind"     => item.kind,
              "secret"   => item.secret ? "1" : nil,
              "required" => item.required ? "1" : nil,
              "value"    => adapter.code == selected ? values[item.name]? || item.value : item.value,
              "stored"   => item.stored ? "1" : nil,
              "choices"  => item.choices.join(","),
              "errors"   => adapter.code == selected ? errors[item.name]?.try(&.join(" ")) : nil,
            })
          end
          AdapterCard.new(adapter.code, I18n.t(adapter.label_key),
            !!connection.try { |item| item.adapter == adapter.code && item.active }, fields,
            adapter.fields.select { |item| item.kind == "choice" }.flat_map(&.choices)
              .map { |choice| Ui.row({"value" => choice, "label" => I18n.t("einvoicing.modes.#{choice}")}) })
        end
        page("einvoicing/settings.html", {
          "title"      => I18n.t("einvoicing.menu.settings"),
          "crumbs"     => crumbs("core.menu.settings", "einvoicing.menu.settings", nil),
          "adapters"   => adapters,
          "connection" => connection_row,
          "base"       => errors["base"]?.try(&.join(" ")) || errors["adapter"]?.try(&.join(" ")),
        }, status: status)
      end
    end

    # Essai du raccordement actif.
    class CheckHandler < Handler
      def get
        go(Ui.url("settings"))
      end

      def post
        result = Api.check_connection(current.actor)
        if result.success?
          flash["success"] = I18n.t("einvoicing_ui.flash.checked")
        else
          flash["danger"] = messages(result).join(" ")
        end
        go(Ui.url("settings"))
      end
    end

    # Débranche la plateforme (les paramètres restent enregistrés).
    class DisconnectHandler < Handler
      def get
        go(Ui.url("settings"))
      end

      def post
        Api.disconnect(current.actor)
        flash["success"] = I18n.t("einvoicing_ui.flash.disconnected")
        go(Ui.url("settings"))
      end
    end

    # Annuaire de la facturation électronique (`/ext/EINV/directory`) :
    # recherche d'une adresse de facturation par SIREN, SIRET ou adresse.
    class DirectoryHandler < Handler
      def get
        search = query("q")
        results = nil
        errors = nil
        unless search.empty?
          result = Api.lookup(current.actor, search)
          if result.success?
            results = result.value!.map do |entry|
              Ui.row({
                "address" => entry.address, "scheme" => entry.scheme, "name" => entry.name, "siren" => entry.siren,
                "siret" => entry.siret, "routing" => entry.routing_id, "platform" => entry.platform,
                "status" => entry.status, "card" => entry.card_code,
                "card_url" => entry.card_code.try { Ui.route("cards:index") }.try { |url| "#{url}?q=#{URI.encode_www_form(entry.siren)}" },
              })
            end
          else
            errors = messages(result)
          end
        end
        page("einvoicing/directory.html", {
          "title"      => I18n.t("einvoicing.menu.directory"),
          "crumbs"     => crumbs("core.menu.reference", "einvoicing.menu.directory", nil),
          "search"     => search,
          "results"    => results.try { |items| listed(items) },
          "searched"   => !search.empty? && errors.nil?,
          "errors"     => errors,
          "connection" => connection_row,
        })
      end
    end
  end
end
