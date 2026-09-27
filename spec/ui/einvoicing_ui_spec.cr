# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api

private def received(browser : PartiduoUi::Browser) : Api::ReceptionView
  S.supplier
  S.platform.deliver(S.ubl_invoice, "FM-2026-0412.xml", "UBL")
  browser.post("/ext/EINV/sync", {"next" => "/ext/EINV/incoming"}).status.should eq(302)
  Api.receptions(S.admin).first
end

describe "Écrans de la facturation électronique sous /ext/EINV/ (ADR-005 D4)" do
  it "est montée sous le code de l'extension, avec ses permissions" do
    Marten.routes.reverse("einv:incoming").should eq("/ext/EINV/incoming")
    Marten.routes.reverse("einv:outgoing_file", id: 3, format: "ubl").should eq("/ext/EINV/outgoing/3/file/ubl")
    mount = PartiduoUi::Extensions["EINV"]? || raise("interface non montée")
    mount.permission.should eq(Api::READ)
    mount.permission_for("einv:refuse").should eq(Api::RECEIVE)
    mount.permission_for("einv:transmit").should eq(Api::SEND)
    mount.permission_for("einv:settings").should eq(Api::CONFIGURE)
    mount.permission_for("einv:directory").should eq(Api::READ)
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/EINV/incoming").status.should eq(404)
  end

  it "raccorde la plateforme : paramètres, secret jamais réaffiché, mode affiché en permanence" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    page = browser.get("/ext/EINV/settings")
    page.status.should eq(200)
    html = page.html
    html.should contain("<h1>Plateforme agréée")
    html.should contain("API normalisée XP Z12-013")
    html.should_not contain("Point d'accès NOALYSS-PEPPOL")
    html.should contain("Aucune plateforme agréée n'est raccordée")
    fields = {"adapter" => "AFNOR", "flow_url" => "http://pa.test/afnor-flow", "directory_url" => "",
              "token_url" => "https://pa.test/oauth2/token", "client_id" => S::SimulatedPlatform::CLIENT_ID,
              "client_secret" => S::SimulatedPlatform::CLIENT_SECRET, "organization_id" => "", "environment" => "sandbox"}
    refused = browser.post("/ext/EINV/settings", fields)
    refused.status.should eq(422)
    refused.html.should contain("Adresse HTTPS attendue")
    browser.post("/ext/EINV/settings", fields.merge({"flow_url" => "https://pa.test/afnor-flow"})).status.should eq(302)
    html = browser.get("/ext/EINV/settings").html
    html.should contain("Plateforme agréée raccordée.")
    html.should contain(%(data-einv-mode="sandbox"))
    html.should contain("Bac à sable")
    html.should_not contain(S::SimulatedPlatform::CLIENT_SECRET)
    html.should contain("Enregistré — laissez vide pour le garder")
    browser.post("/ext/EINV/settings/check").status.should eq(302)
    browser.get("/ext/EINV/settings").html.should contain("La plateforme répond.")
    # Le mode est rappelé sur les listes.
    browser.get("/ext/EINV/incoming").html.should contain(%(data-einv-mode="sandbox"))
  end

  it "liste les factures émises avec leur statut, signale la plateforme requise, transmet et remonte le statut" do
    browser = S.signed_in
    invoice = S.issue
    off = S.issue(channel: "paper")
    html = browser.get("/ext/EINV/outgoing").html
    html.should contain("<h1>Factures électroniques émises")
    html.should contain(invoice.number.to_s)
    html.should contain(%(data-einv-status="pending"))
    html.should contain("Plateforme requise")
    html.should contain(%(<span class="pd-count" data-pd-count="EINV_OUT">1</span>))
    row = S.transmission(invoice)
    show = browser.get("/ext/EINV/outgoing/#{row.id}").html
    show.should contain("Transmettre à la plateforme")
    show.should contain("CII EXTENDED-CTC-FR")
    browser.post("/ext/EINV/outgoing/#{row.id}/transmit").status.should eq(302)
    browser.get("/ext/EINV/outgoing/#{row.id}").html.should contain("Facture #{invoice.number} transmise à la plateforme.")
    S.platform.acknowledge(S.platform.sent("CustomerInvoice").first, "Ok")
    browser.post("/ext/EINV/sync", {"next" => "/ext/EINV/outgoing"}).headers["Location"].should eq("/ext/EINV/outgoing")
    show = browser.get("/ext/EINV/outgoing/#{row.id}").html
    show.should contain(%(data-einv-status="deposited"))
    show.should contain(%(data-einv-event="200"))
    required = browser.get("/ext/EINV/outgoing/#{S.transmission(off).id}").html
    required.should contain("la réforme impose l'émission par la plateforme agréée")
    file = browser.get("/ext/EINV/outgoing/#{row.id}/file/ubl")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should contain("#{invoice.number}-ubl.xml")
    browser.get("/ext/EINV/outgoing/#{row.id}/file/docx").status.should eq(404)
  end

  it "montre une facture reçue, ses doublons et l'écriture proposée, puis la pré-comptabilise" do
    browser = S.signed_in
    view = received(browser)
    list = browser.get("/ext/EINV/incoming").html
    list.should contain("Fournitures Martin SAS")
    list.should contain(%(<span class="pd-count" data-pd-count="EINV_IN">1</span>))
    html = browser.get("/ext/EINV/incoming/#{view.id}").html
    html.should contain("Facture FM-2026-0412 de Fournitures Martin SAS")
    html.should contain("Ramettes de papier")
    html.should contain(%(data-einv-prefill))
    html.should contain("Pré-comptabiliser")
    html.should contain("Refuser la facture")
    browser.post("/ext/EINV/incoming/#{view.id}/post").status.should eq(302)
    html = browser.get("/ext/EINV/incoming/#{view.id}").html
    html.should contain("enregistrée dans le journal d'achats")
    html.should contain(%(data-einv-status="posted"))
    html.should contain("Voir l'écriture d'achat")
    html.should_not contain("Refuser la facture")
  end

  it "refuse une facture reçue avec un motif ; un motif manquant est signalé" do
    browser = S.signed_in
    view = received(browser)
    missing = browser.post("/ext/EINV/incoming/#{view.id}/refuse", {"reason_code" => "AUTRE", "reason" => ""})
    missing.status.should eq(422)
    missing.html.should contain("Précisez le motif du refus.")
    browser.post("/ext/EINV/incoming/#{view.id}/refuse", {"reason_code" => "DOUBLON", "reason" => "reçue deux fois"}).status.should eq(302)
    html = browser.get("/ext/EINV/incoming/#{view.id}").html
    html.should contain("le statut « Refusée » est transmis au fournisseur")
    html.should contain(%(data-einv-event="210"))
    html.should contain("Facture en double : reçue deux fois")
  end

  it "reçoit à la main un fichier UBL déposé" do
    browser = S.signed_in
    page = browser.get("/ext/EINV/incoming").html
    page.should contain(%(enctype="multipart/form-data"))
    response = S.upload(browser, "/ext/EINV/incoming/import", {} of String => String, {"file", "pb.xml", S.cii_invoice})
    response.status.should eq(302)
    browser.get(response.headers["Location"]).html.should contain("Plomberie Bernard")
    bad = S.upload(browser, "/ext/EINV/incoming/import", {} of String => String, {"file", "note.txt", "bonjour".to_slice})
    bad.status.should eq(422)
    bad.html.should contain("Ni UBL, ni CII, ni Factur-X")
  end

  it "cherche dans l'annuaire" do
    browser = S.signed_in
    S.platform.directory << JSON.parse({"addressingIdentifier" => S::CUSTOMER_SIREN, "siren" => S::CUSTOMER_SIREN,
                                        "platformType" => "WK", "directoryLineStatus" => "Enabled",
                                        "legalUnit" => {"businessName" => "Atelier Morel SAS"}}.to_json).as_h
    html = browser.get("/ext/EINV/directory?q=#{S::CUSTOMER_SIREN}").html
    html.should contain("<h1>Annuaire de facturation électronique")
    html.should contain("Atelier Morel SAS")
    html.should contain("(0225)")
    browser.get("/ext/EINV/directory?q=ab").html.should contain("Saisissez au moins trois caractères.")
  end

  it "refuse les écrans de décision à un lecteur" do
    S.books
    profile = PartiduoUi::Accounts.profile("Lecteur EINV", [Api::READ])
    PartiduoUi::Accounts.create(email: "bob@example.com", profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in("bob@example.com")
    browser.get("/ext/EINV/incoming").status.should eq(200)
    browser.get("/ext/EINV/settings").status.should eq(403)
    browser.post("/ext/EINV/incoming/1/refuse", {"reason_code" => "AUTRE"}).status.should eq(403)
  end
end
