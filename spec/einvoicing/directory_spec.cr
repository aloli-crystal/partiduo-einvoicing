# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api

private def line(address : String, siren : String, siret : String = "", routing : String = "") : Hash(String, JSON::Any)
  JSON.parse({"addressingIdentifier" => address, "siren" => siren, "siret" => siret, "routingIdentifier" => routing,
              "platformType" => "WK", "directoryLineStatus" => "Enabled",
              "legalUnit" => {"siren" => siren, "businessName" => "Atelier Morel SAS"}}.to_json).as_h
end

describe "Annuaire de la facturation électronique (API Annuaire XP Z12-013, ADR-004 D8)" do
  it "cherche par SIREN, SIRET ou adresse, et cite la fiche du socle de même SIREN" do
    S.books
    S.connect_afnor
    S.customer
    S.platform.directory << line(S::CUSTOMER_SIREN, S::CUSTOMER_SIREN)
    S.platform.directory << line("#{S::CUSTOMER_SIREN}_#{S::CUSTOMER_SIREN}00012", S::CUSTOMER_SIREN, "#{S::CUSTOMER_SIREN}00012")
    S.platform.directory << line("#{S::CUSTOMER_SIREN}_#{S::CUSTOMER_SIREN}00012_COMPTA", S::CUSTOMER_SIREN,
      "#{S::CUSTOMER_SIREN}00012", "COMPTA")
    entries = Api.lookup(S.admin, "552 100 554").value!
    entries.size.should eq(3)
    entries.first.name.should eq("Atelier Morel SAS")
    entries.map(&.scheme).uniq!.should eq(["0225"])
    entries.map(&.card_code).uniq!.should eq(["CLI-MOREL"])
    entries.last.routing_id.should eq("COMPTA")
    body = JSON.parse(String.new(S.platform.requests.last.body || Bytes.empty))
    body["filters"]["siren"]["op"].should eq("strict")
    Api.lookup(S.admin, "#{S::CUSTOMER_SIREN}00012").value!.size.should eq(2)
    Api.lookup(S.admin, "COMPTA").value!.size.should eq(1)
    Api.lookup(S.admin, "ab").errors.first.key.should eq("einvoicing.errors.directory.too_short")
  end

  it "signale l'absence de raccordement" do
    S.books
    Api.lookup(S.admin, "552100554").errors.first.key.should eq("einvoicing.errors.connection.missing")
  end
end
