# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Factures reçues (ADR-004 D3, D9) : lecture (UBL, CII, Factur-X), dépôt
  # dans la boîte « Justificatifs à traiter » de DOCUMENT par son API
  # publique (`Document::Api.receive`, pièces jointes du socle),
  # rapprochement de la fiche du fournisseur, doublons,
  # pré-comptabilisation par le service d'écriture de la Comptabilité.
  # Interne.
  module Incoming
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    SYSTEM = Partiduo::Api::Actor.system

    # `external_ref` d'une facture reçue dans DOCUMENT.
    EXTERNAL_PREFIX = "einvoicing:"

    # Enregistre une facture reçue (idempotent sur `platform_ref`) : lue si
    # possible, déposée dans la boîte à traiter. Une facture illisible est
    # gardée telle quelle, avec ses erreurs de lecture.
    def self.store!(incoming : Connector::IncomingInvoice, adapter : String) : Reception
      if existing = Reception.filter(platform_ref: incoming.platform_ref).first
        return existing
      end
      parsed, read_errors = begin
        {Formats::Reader.parse(incoming.content), [] of String}
      rescue ex : Formats::ReadError
        {nil, [ex.message.to_s]}
      end
      card = parsed.try { |invoice| supplier_card(invoice.seller) }
      receipt = deposit(incoming, parsed, card)
      seller = parsed.try(&.seller) || Formats::PartyData.new(name: incoming.sender)
      Reception.create!(
        platform_ref: incoming.platform_ref, adapter: adapter, receipt_id: receipt.id,
        syntax: parsed.try(&.syntax) || incoming.syntax || "", profile: cut(parsed.try(&.profile), 120),
        type_code: cut(parsed.try(&.type_code), 3), number: cut(parsed.try(&.number), 100),
        issue_date: parsed.try(&.issue_date), due_date: parsed.try(&.due_date),
        currency_code: cut(parsed.try(&.currency_code), 3), supplier_name: cut(seller.name, 255),
        supplier_siren: cut(seller.siren, 9), supplier_vat: cut(seller.vat_number, 32),
        supplier_country: cut(seller.country_code, 2), supplier_card_id: card.try(&.id),
        buyer_siren: cut(parsed.try(&.buyer.siren), 9), total_net: parsed.try(&.total_net),
        total_vat: parsed.try(&.total_vat), total_gross: parsed.try(&.total_gross), payable: parsed.try(&.payable),
        data: JSON.parse(data_of(parsed, read_errors).to_json), status: "received", received_at: incoming.received_at,
      )
    end

    private def self.cut(text : String?, size : Int32) : String
      value = text || ""
      value.size > size ? value[0, size] : value
    end

    # Dépôt dans la boîte « Justificatifs à traiter » : le PDF lisible d'un
    # Factur-X avec son XML embarqué en données structurées, ou le XML
    # lui-même (UBL, CII).
    private def self.deposit(incoming : Connector::IncomingInvoice, parsed : Formats::Parsed?,
                             card : Partiduo::Api::Cards::CardView?) : Document::Api::ReceiptView
      pdf = parsed.try(&.syntax) == "Factur-X"
      details = Document::Api::DetailsInput.new(
        supplier_name: parsed.try(&.seller.name) || incoming.sender,
        supplier_code: card.try(&.code),
        amount: parsed.try(&.total_gross).try { |value| value >= 0 ? value.round(4) : nil },
        currency_code: parsed.try(&.currency_code).to_s.matches?(/\A[A-Z]{3}\z/) ? parsed.try(&.currency_code).to_s : "",
        date: parsed.try(&.issue_date),
        kind: "invoice",
        reference: cut(parsed.try(&.number), 100),
        note: I18n.t("einvoicing.receipt_note", syntax: parsed.try(&.syntax) || "?"),
      )
      input = Document::Api::ReceiveInput.new(
        filename: incoming.filename, content: incoming.content, external_ref: "#{EXTERNAL_PREFIX}#{incoming.platform_ref}",
        details: details, data_filename: pdf ? "factur-x.xml" : nil, data: pdf ? parsed.try(&.xml) : nil,
      )
      result = Document::Api.receive(SYSTEM, input)
      return result.value! if result.success?
      # Compléments refusés (fiche illisible, montant) : le fichier est gardé
      # sans eux plutôt que perdu.
      Document::Api.receive(SYSTEM, input.copy_with(details: Document::Api::DetailsInput.new(kind: "invoice"))).value!
    end

    private def self.data_of(parsed : Formats::Parsed?, errors : Array(String)) : Hash(String, JSON::Any)
      data = {} of String => JSON::Any
      data["errors"] = JSON.parse((errors + (parsed.try(&.errors) || [] of String)).to_json)
      return data if parsed.nil?
      data["lines"] = JSON.parse(parsed.lines.map(&.to_h).to_json)
      data["vat_lines"] = JSON.parse(parsed.vat_lines.map(&.to_h).to_json)
      data["notes"] = JSON.parse(parsed.notes.to_json)
      data["seller"] = JSON.parse(parsed.seller.to_h.to_json)
      data["buyer"] = JSON.parse(parsed.buyer.to_h.to_json)
      data
    end

    # Fiche du fournisseur : de même SIREN, sinon de même numéro de TVA.
    def self.supplier_card(seller : Formats::PartyData) : Partiduo::Api::Cards::CardView?
      [seller.siren, seller.vat_number.gsub(/\s/, "")].reject(&.empty?).each do |key|
        cards = Partiduo::Api::Cards.cards(SYSTEM, Partiduo::Api::Cards::CardQuery.new(search: key, limit: 20))
        found = cards.find { |card| card.siren == key || card.vat_number.gsub(/\s/, "").upcase == key.upcase }
        return found if found
      end
      nil
    end

    def self.lock!(id : Int64) : Reception
      Reception.all.lock.filter(id: id).first || raise Partiduo::Api::NotFound.new("reception", id)
    end

    def self.find!(id : Int64) : Reception
      Reception.filter(id: id).first || raise Partiduo::Api::NotFound.new("reception", id)
    end

    def self.decide!(row : Reception, status : String, by : Int64?) : Reception
      row.status = status
      row.decided_at = Time.utc
      row.decided_by_id = by
      row.save!
      row
    end

    # Autres factures reçues par la plateforme du même fournisseur (fiche
    # ou SIREN) et de même numéro normalisé, non refusées.
    def self.same_invoices(row : Reception) : Array(Reception)
      number = normalize(row.number.to_s)
      return [] of Reception if number.empty?
      candidates = Reception.exclude(id: row.id).exclude(status: "refused")
      candidates = if card = row.supplier_card_id
                     candidates.filter(supplier_card_id: card)
                   elsif !(siren = row.supplier_siren.to_s).empty?
                     candidates.filter(supplier_siren: siren)
                   else
                     return [] of Reception
                   end
      candidates.to_a.select { |other| normalize(other.number.to_s) == number }
    end

    # Numéro sans casse, espaces ni séparateurs (même règle que le cœur,
    # `accounting_received_invoice`).
    def self.normalize(number : String) : String
      number.upcase.gsub(/[\s\-_.\/]/, "")
    end

    # Écriture d'achat préremplie : premier journal d'achats où l'acteur
    # écrit, date de la facture, fiche du fournisseur, une ligne par taux de
    # TVA du récapitulatif (hors taxe et TVA de la facture, signés pour un
    # avoir), pièce jointe = le fichier reçu, source `document:<id>` pour que
    # DOCUMENT rattache le justificatif (D-DOC-003).
    def self.prefill(actor : Partiduo::Api::Actor, row : Reception, view : Api::ReceptionView) : {Acc::ReceivedInvoiceInput?, Array(FieldError)}
      errors = [] of FieldError
      ledger = Acc.ledgers(actor, Acc::LedgerKind::Purchase, enabled_only: true).find(&.access.write?)
      errors << FieldError.new("ledger_id", "einvoicing.errors.reception.no_purchase_ledger") if ledger.nil?
      # Compte de charge : celui du journal d'achats (DECISIONS D-EINV-010).
      if ledger && ledger.default_account.nil?
        errors << FieldError.new("account", "einvoicing.errors.reception.account_missing", {"ledger" => ledger.code})
      end
      card = view.supplier_card_id.try { |id| Partiduo::Api::Cards.card(SYSTEM, id) rescue nil }
      errors << FieldError.new("supplier", "einvoicing.errors.reception.supplier_unknown",
        {"name" => view.supplier_name, "siren" => view.supplier_siren}) if card.nil?
      errors << FieldError.new("number", "einvoicing.errors.reception.number_missing") if view.number.empty?
      receipt = view.receipt_id.try { |id| Document::Api.receipt(SYSTEM, id) }
      errors << FieldError.new("base", "einvoicing.errors.reception.no_file") if receipt.nil?
      return {nil, errors} unless errors.empty? && ledger && card && receipt

      sign = view.credit_note? ? -1 : 1
      rates = actor.can?("vat.rate.read") ? Partiduo::Api::Vat.rates(actor) : [] of Partiduo::Api::Vat::RateView
      label = [view.supplier_name, view.number].reject(&.empty?).join(" · ")
      lines = view.vat_lines.map do |vat|
        rate = match_rate(rates, vat.category, vat.percent)
        Acc::DocumentLineInput.new(amount: vat.base * sign, vat_rate: rate.try(&.code),
          vat_amount: rate ? vat.amount * sign : nil, label: label)
      end
      if lines.empty?
        lines << Acc::DocumentLineInput.new(amount: (view.total_net || view.total_gross || BigDecimal.new(0)) * sign, label: label)
      end
      document = Acc::DocumentInput.new(
        ledger_id: ledger.id, date: view.issue_date || Partiduo::Api::Core.today, third_party: card.code,
        lines: lines, label: label, due_date: view.due_date,
        currency_code: view.currency_code.presence, attachment_id: receipt.original_attachment_id,
        source: "#{Document::Api::SOURCE_PREFIX}#{receipt.id}",
      )
      {Acc::ReceivedInvoiceInput.new(document: document, number: view.number, invoice_date: view.issue_date,
        origin: Acc::ReceptionOrigin::Platform, platform_reference: cut(view.platform_ref, 255)), errors}
    end

    # Taux du dossier de même catégorie et même pourcentage (hors
    # autoliquidation d'abord).
    private def self.match_rate(rates : Array(Partiduo::Api::Vat::RateView), category : String,
                                percent : BigDecimal) : Partiduo::Api::Vat::RateView?
      candidates = rates.select { |rate| rate.enabled && rate.rate == percent && (category.empty? || rate.category == category) }
      candidates.find { |rate| !rate.reverse_charge } || candidates.first?
    end

    def self.view(row : Reception) : Api::ReceptionView
      data = row.data.try(&.as_h?) || {} of String => JSON::Any
      lines = (data["lines"]?.try(&.as_a?) || [] of JSON::Any).map do |line|
        item = Formats::LineData.from_h(line.as_h? || {} of String => JSON::Any)
        Api::LineView.new(item.description, item.quantity, item.unit_code, item.unit_price, item.net, item.vat_category,
          item.vat_percent)
      end
      vat_lines = (data["vat_lines"]?.try(&.as_a?) || [] of JSON::Any).map do |line|
        item = Formats::VatLine.from_h(line.as_h? || {} of String => JSON::Any)
        Api::VatLineView.new(item.category, item.percent, item.base, item.amount)
      end
      strings = ->(key : String) { (data[key]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?) }
      Api::ReceptionView.new(
        id: row.id!.to_i64, platform_ref: row.platform_ref!, adapter: row.adapter || "",
        receipt_id: row.receipt_id.try(&.to_i64), syntax: row.syntax || "", profile: row.profile || "",
        type_code: row.type_code || "", number: row.number || "", issue_date: row.issue_date, due_date: row.due_date,
        currency_code: row.currency_code || "", supplier_name: row.supplier_name || "",
        supplier_siren: row.supplier_siren || "", supplier_vat: row.supplier_vat || "",
        supplier_country: row.supplier_country || "", supplier_card_id: row.supplier_card_id.try(&.to_i64),
        buyer_siren: row.buyer_siren || "", total_net: row.total_net, total_vat: row.total_vat,
        total_gross: row.total_gross, payable: row.payable, lines: lines, vat_lines: vat_lines,
        notes: strings.call("notes"), read_errors: strings.call("errors"), status: row.status!,
        entry_id: row.entry_id.try(&.to_i64), received_invoice_id: row.received_invoice_id.try(&.to_i64),
        decided_at: row.decided_at, received_at: row.received_at!,
      )
    end
  end
end
