# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Ui
    # Base des écrans de l'extension : coquille de l'application, fil
    # d'Ariane, raccordement actif. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ;
    # `Einvoicing::Api` le vérifie encore.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Einvoicing::Api

      def crumbs(rubric : String, list_label : String, list_url : String?, current_label : String? = nil) : Array(PartiduoUi::Screen::Crumb)
        items = [crumb(rubric), PartiduoUi::Screen::Crumb.new(I18n.t(list_label), current_label ? list_url : nil)]
        items << PartiduoUi::Screen::Crumb.new(current_label) if current_label
        items
      end

      # Raccordement actif, présenté pour l'en-tête des écrans (adaptateur,
      # mode bac à sable ou production, dernière synchronisation).
      def connection_row : Row?
        Api.connection(current.actor).try do |connection|
          Ui.row({
            "adapter"    => I18n.t(connection.label_key),
            "mode"       => connection.mode,
            "mode_label" => I18n.t("einvoicing.modes.#{connection.mode}"),
            "last_sync"  => connection.last_sync_at.try { |time| fmt.datetime(time) },
            "error"      => connection.last_error.presence,
          })
        end
      end

      def can_sync? : Bool
        can?(Api::SEND) || can?(Api::RECEIVE)
      end

      def status_tabs(statuses : Array(String), current_status : String?, key : String, route : String) : Array(Row)
        all = Ui.row({"code" => "", "label" => I18n.t("einvoicing_ui.tabs.all"), "url" => "#{Ui.url(route)}?status=all",
                      "current" => current_status.nil? ? "1" : nil})
        [all] + statuses.map do |code|
          Ui.row({"code" => code, "label" => I18n.t("#{key}.#{code}"), "url" => "#{Ui.url(route)}?status=#{code}",
                  "current" => code == current_status ? "1" : nil})
        end
      end

      def messages(result) : Array(String)
        result.errors.map { |error| fmt.message(error) }
      end
    end

    # `/ext/EINV/` : les factures reçues, premier écran utile.
    class IndexHandler < Handler
      def get
        go(Ui.url("incoming"))
      end
    end

    # Synchronisation avec la plateforme (bouton des écrans de listes).
    class SyncHandler < Handler
      def get
        go(Ui.url("incoming"))
      end

      def post
        back = field("next")
        back = Ui.url("incoming") unless back.starts_with?("/ext/EINV/")
        result = Api.synchronize(current.actor)
        if result.success?
          sync = result.value!
          flash["success"] = I18n.t("einvoicing_ui.flash.synced", transmitted: sync.transmitted, received: sync.received,
            statuses: sync.statuses + sync.sent_statuses, reports: sync.reports)
          flash["warning"] = sync.errors.first(3).join(" ; ") unless sync.errors.empty?
        else
          flash["danger"] = messages(result).join(" ")
        end
        go(back)
      end
    end
  end
end
