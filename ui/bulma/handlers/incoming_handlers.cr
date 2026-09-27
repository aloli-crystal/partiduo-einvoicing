# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Ui
    # Factures électroniques reçues (`/ext/EINV/incoming`) : onglets par
    # statut, synchronisation, dépôt manuel d'un fichier UBL, CII ou
    # Factur-X.
    class IncomingHandler < Handler
      def get
        show([] of String)
      end

      def show(errors : Array(String), status : Int32 = 200) : Marten::HTTP::Response
        wanted = query("status")
        current_status = wanted == "all" ? nil : (Api::RECEPTION_STATUSES.includes?(wanted) ? wanted : "received")
        search = query("q")
        views = Api.receptions(current.actor, Api::ReceptionQuery.new(status: current_status, search: search.presence))
        page("einvoicing/incoming.html", {
          "title"      => I18n.t("einvoicing.menu.incoming"),
          "crumbs"     => crumbs("core.menu.entry", "einvoicing.menu.incoming", nil),
          "tabs"       => status_tabs(Api::RECEPTION_STATUSES, current_status, "einvoicing.reception_statuses", "incoming"),
          "rows"       => listed(views.map { |view| Present.reception(view, fmt) }),
          "search"     => search,
          "status"     => current_status || "all",
          "connection" => connection_row,
          "can_sync"   => can_sync?,
          "can_import" => can?(Api::RECEIVE) && can?(Document::Api::WRITE) && can?(Document::Api::ATTACHMENT_WRITE),
          "errors"     => listed(errors),
          "sync_next"  => request.full_path,
        }, status: status)
      end
    end

    # Dépôt manuel d'une facture électronique reçue hors synchronisation.
    class ImportHandler < IncomingHandler
      def get
        go(Ui.url("incoming"))
      end

      def post
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        return show([I18n.t("einvoicing_ui.errors.file_missing")], 422) if upload.nil?
        io = upload.io
        io.rewind
        content = io.getb_to_end
        return show([I18n.t("einvoicing_ui.errors.file_missing")], 422) if content.empty?
        result = Api.import(current.actor, upload.filename || "", content)
        return show(messages(result), 422) if result.failure?
        flash["success"] = I18n.t("einvoicing_ui.flash.imported")
        go(Ui.url("incoming_show", result.value!.id))
      ensure
        upload.try { |file| file.io.delete rescue nil }
      end
    end

    # Consultation d'une facture reçue : fournisseur, lignes, TVA, doublons,
    # écriture proposée, décisions (accepter, refuser, pré-comptabiliser).
    class IncomingShowHandler < Handler
      def get
        show(Api.reception(current.actor, id_param), [] of String)
      end

      def show(view : Api::ReceptionView, errors : Array(String), status : Int32 = 200) : Marten::HTTP::Response
        actor = current.actor
        duplicates = Api.duplicates(actor, view.id)
        can_receive = can?(Api::RECEIVE)
        can_post = can_receive && module_active?("ACCOUNTING") && can?("accounting.entry.post")
        prefill_lines = nil
        prefill_errors = nil
        if can_post && view.undecided?
          prefill = Api.purchase_prefill(actor, view.id)
          if prefill.success?
            prefill_lines = prefill.value!.document.lines.map do |line|
              Ui.row({"label" => line.label, "amount" => fmt.amount(line.amount), "vat_rate" => line.vat_rate || "—",
                      "vat_amount" => line.vat_amount.try { |value| fmt.amount(value) } || "—"})
            end
          else
            prefill_errors = messages(prefill)
          end
        end
        row = Present.reception(view, fmt)
        page("einvoicing/incoming_show.html", {
          "title" => I18n.t("einvoicing_ui.incoming.show_title", number: view.number.presence || "—",
            supplier: view.supplier_name.presence || "—"),
          "crumbs" => crumbs("core.menu.entry", "einvoicing.menu.incoming", Ui.url("incoming"), view.number.presence || "#{view.id}"),
          "row"    => row,
          "lines"  => listed(view.lines.map do |line|
            Ui.row({"description" => line.description, "quantity" => fmt.number(line.quantity), "unit" => line.unit_code,
                    "price" => line.unit_price.try { |value| fmt.amount(value) }, "net" => fmt.amount(line.net),
                    "vat" => line.vat_percent.try { |value| "#{line.vat_category} #{fmt.percent(value)}" } || line.vat_category})
          end),
          "vat_lines" => listed(view.vat_lines.map do |vat|
            Ui.row({"category" => vat.category, "percent" => fmt.percent(vat.percent), "base" => fmt.amount(vat.base),
                    "amount" => fmt.amount(vat.amount)})
          end),
          "notes"      => listed(view.notes),
          "events"     => listed(Api.reception_events(actor, view.id).map { |event| Present.event(event, fmt) }),
          "duplicates" => listed(duplicates.receptions.map { |other| Present.reception(other, fmt) }),
          "recorded"   => listed(duplicates.received_invoices.map do |item|
            # Écriture d'un journal que l'utilisateur ne lit pas : le seul
            # signal de doublon (D-ACC-020).
            Ui.row({"number" => item.number, "date" => fmt.date(item.invoice_date),
                    "amount" => item.restricted ? "" : fmt.amount(item.total_amount),
                    "origin" => I18n.t(item.origin_key), "receipt" => item.receipt || "",
                    "url" => item.restricted ? nil : Ui.route("accounting:entry", id: item.entry_id)})
          end),
          "can_receive"    => can_receive && view.undecided?,
          "can_accept"     => can_receive && view.status == "received",
          "can_post"       => can_post && view.undecided?,
          "prefill"        => prefill_lines,
          "prefill_errors" => prefill_errors,
          "reasons"        => Api::REFUSAL_REASONS.map { |code| Ui.row({"code" => code, "label" => I18n.t("einvoicing.refusal_reasons.#{code}")}) },
          "errors"         => listed(errors),
          "can_files"      => can?(Document::Api::READ) && can?(Document::Api::ATTACHMENT_READ),
        }, status: status)
      end
    end

    # Décisions sur une facture reçue.
    abstract class DecisionHandler < IncomingShowHandler
      abstract def decide(id : Int64) : {Bool, Array(String), String}

      def get
        go(Ui.url("incoming_show", id_param))
      end

      def post
        ok, errors, done = decide(id_param)
        return show(Api.reception(current.actor, id_param), errors, 422) unless ok
        flash["success"] = done
        go(Ui.url("incoming_show", id_param))
      end
    end

    class AcceptHandler < DecisionHandler
      def decide(id : Int64) : {Bool, Array(String), String}
        result = Api.accept(current.actor, id)
        {result.success?, messages(result), I18n.t("einvoicing_ui.flash.accepted")}
      end
    end

    class RefuseHandler < DecisionHandler
      def decide(id : Int64) : {Bool, Array(String), String}
        result = Api.refuse(current.actor, id, Api::RefuseInput.new(field("reason_code"), field("reason")))
        {result.success?, messages(result), I18n.t("einvoicing_ui.flash.refused")}
      end
    end

    class PostHandler < DecisionHandler
      def decide(id : Int64) : {Bool, Array(String), String}
        result = Api.post(current.actor, id)
        receipt = result.success? ? (result.value!.receipt || "") : ""
        {result.success?, messages(result), I18n.t("einvoicing_ui.flash.posted", receipt: receipt)}
      end
    end

    # Fichier reçu : l'original, ou son XML.
    class IncomingFileHandler < Handler
      def get
        variant = params["variant"].to_s
        raise Partiduo::Api::NotFound.new("reception_file", id_param) unless {"original", "xml"}.includes?(variant)
        file = Api.reception_file(current.actor, id_param, variant)
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        disposition = file.content_type == "application/pdf" && query("download") != "1" ? "inline" : "attachment"
        response["Content-Disposition"] = %(#{disposition}; filename="#{file.filename.gsub(/["\\\r\n]/, "_")}")
        response["X-Content-Type-Options"] = "nosniff"
        response
      end
    end
  end
end
