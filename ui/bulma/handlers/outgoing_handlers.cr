# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Ui
    # Factures électroniques émises (`/ext/EINV/outgoing`) : route (plateforme,
    # B2C, international, hors plateforme), statut du cycle de vie,
    # signalement des factures que la réforme impose de transmettre.
    class OutgoingHandler < Handler
      def get
        status = query("status")
        current_status = Api::TRANSMISSION_STATUSES.includes?(status) ? status : nil
        search = query("q")
        views = Api.transmissions(current.actor, Api::TransmissionQuery.new(status: current_status, search: search.presence))
        counts = Api.counts(current.actor)
        page("einvoicing/outgoing.html", {
          "title"      => I18n.t("einvoicing.menu.outgoing"),
          "crumbs"     => crumbs("core.menu.billing", "einvoicing.menu.outgoing", nil),
          "tabs"       => status_tabs(Api::TRANSMISSION_STATUSES, current_status, "einvoicing.transmission_statuses", "outgoing"),
          "rows"       => listed(views.map { |view| Present.transmission(view, fmt) }),
          "search"     => search,
          "status"     => current_status || "all",
          "connection" => connection_row,
          "can_sync"   => can_sync?,
          "pending"    => counts.outgoing_pending.to_s,
          "rejected"   => counts.outgoing_rejected.to_s,
          "sync_next"  => request.full_path,
        })
      end
    end

    # Consultation d'une facture émise : statut, événements du cycle de vie,
    # fichiers produits à la demande, transmission.
    class OutgoingShowHandler < Handler
      def get
        view = Api.transmission(current.actor, id_param)
        row = Present.transmission(view, fmt)
        formats = Api::EXPORT_FORMATS.map do |format|
          Ui.row({"label" => I18n.t("einvoicing_ui.formats.#{format.tr("-", "_")}"),
                  "url"   => Ui.url("outgoing_file", view.id, format)})
        end
        page("einvoicing/outgoing_show.html", {
          "title"        => I18n.t("einvoicing_ui.outgoing.show_title", number: view.number),
          "crumbs"       => crumbs("core.menu.billing", "einvoicing.menu.outgoing", Ui.url("outgoing"), view.number),
          "row"          => row,
          "events"       => listed(Api.transmission_events(current.actor, view.id).map { |event| Present.event(event, fmt) }),
          "formats"      => can?("invoicing.invoice.read") && module_active?("INVOICING") ? formats : nil,
          "can_transmit" => can?(Api::SEND) && view.transmittable? && module_active?("INVOICING"),
          "connection"   => connection_row,
        })
      end
    end

    # Transmet (ou retransmet) une facture à la plateforme active.
    class TransmitHandler < Handler
      def get
        go(Ui.url("outgoing_show", id_param))
      end

      def post
        result = Api.transmit(current.actor, id_param)
        if result.success?
          flash["success"] = I18n.t("einvoicing_ui.flash.transmitted", number: result.value!.number)
        else
          flash["danger"] = messages(result).join(" ")
        end
        go(Ui.url("outgoing_show", id_param))
      end
    end

    # Fichier d'une facture émise : Factur-X, CII, EXTENDED-CTC-FR, UBL,
    # PEPPOL.
    class OutgoingFileHandler < Handler
      def get
        format = params["format"].to_s
        raise Partiduo::Api::NotFound.new("einvoicing_format", id_param) unless Api::EXPORT_FORMATS.includes?(format)
        view = Api.transmission(current.actor, id_param)
        file = Api.export(current.actor, view.invoice_id, format)
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename.gsub(/["\\\r\n]/, "_")}")
        response["X-Content-Type-Options"] = "nosniff"
        response
      end
    end
  end
end
