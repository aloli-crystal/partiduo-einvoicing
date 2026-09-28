# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport

# Adaptateur hérité de l'adaptateur XP Z12-013, comme celui d'une plateforme
# qui s'écarte de la norme (`partiduo-esalink`, DECISIONS D-ESL-002).
private class DerivedAfnor < Einvoicing::Connectors::Afnor
  getter authentications = 0
  property full_read = 0

  protected def platform_headers : Hash(String, String)
    super.merge({"X-Platform-Key" => "cle"})
  end

  protected def request_url(url : String, request_id : String) : String
    "#{url}#{url.includes?('?') ? '&' : '?'}Request-Id=#{request_id}"
  end

  protected def download_accept : String
    "application/octet-stream"
  end

  protected def page_limit : Int32
    2
  end

  protected def more_without_cursor?(body : JSON::Any, results : Array(JSON::Any)) : Bool
    (body["total"]?.try(&.as_i?) || 0) > results.size
  end

  protected def full_read_limit : Int32
    full_read
  end

  protected def authenticate : String
    @authentications += 1
    super
  end
end

private def derived : DerivedAfnor
  settings = Einvoicing::Connections::Settings.new("AFNOR", {
    "flow_url" => "https://pa.test/afnor-flow", "token_url" => "https://pa.test/oauth2/token",
    "client_id" => S::SimulatedPlatform::CLIENT_ID, "environment" => "sandbox",
  }, {"client_secret" => S::SimulatedPlatform::CLIENT_SECRET})
  DerivedAfnor.new(settings)
end

describe "Adaptateur XP Z12-013 : points d'extension d'un adaptateur hérité" do
  it "ajoute en-têtes et adresse propres, et le type accepté au téléchargement" do
    platform = S.platform
    platform.deliver(S.ubl_invoice, "a.xml", "UBL")
    connector = derived
    page = connector.fetch_incoming(nil)
    page.items.size.should eq(1)
    connector.authentications.should be > 0
    search = platform.requests.find!(&.url.includes?("/v1/flows/search"))
    search.headers["X-Platform-Key"].should eq("cle")
    search.url.should end_with("?Request-Id=#{search.headers["Request-Id"]}")
    download = platform.requests.find! { |request| request.method == "GET" && request.url.includes?("docType=Original") }
    download.headers["Accept"].should eq("application/octet-stream")
    download.url.should contain("docType=Original&Request-Id=")
  end

  %w[asc desc shuffled].each do |order|
    it "relit d'un seul appel une recherche sans curseur incomplète (flux rendus dans l'ordre #{order})" do
      platform = S.platform
      platform.cursorless = true
      platform.page_size = 100
      platform.result_order = order
      5.times { |index| platform.deliver(S.ubl_invoice("FM-#{index}"), "f#{index}.xml", "UBL") }
      connector = derived
      connector.full_read = 1000
      page = connector.fetch_incoming(nil)
      page.has_more.should be_false
      page.items.map(&.platform_ref).should eq(platform.flows.sort_by(&.updated_at).map(&.id))
      limits = platform.requests.select(&.url.includes?("/v1/flows/search")).map { |request| JSON.parse(String.new(request.body || Bytes.empty))["limit"].as_i }
      limits.should eq([2, 5])
    end
  end

  it "au-delà de la relecture complète, pagine par date avec recul, sans perte ni relecture sans fin" do
    platform = S.platform
    platform.cursorless = true
    5.times { |index| platform.deliver(S.ubl_invoice("FM-#{index}"), "f#{index}.xml", "UBL") }
    base = Time.utc
    platform.flows.each_with_index { |flow, index| flow.updated_at = base + (index * 5).seconds }
    connector = derived
    seen = [] of String
    cursor = nil
    pages = 0
    10.times do
      page = connector.fetch_incoming(cursor)
      pages += 1
      seen.concat(page.items.map(&.platform_ref))
      cursor = page.cursor
      break unless page.has_more
    end
    pages.should be < 10
    seen.uniq.sort!.should eq(platform.flows.map(&.id).sort!)
    # Nouvelle synchronisation : recouvrement de dix minutes, flux déjà vus
    # relus (écartés par l'enregistrement idempotent).
    connector.fetch_incoming(cursor).items.map(&.platform_ref).each { |ref| seen.should contain(ref) }
  end

  it "s'arrête quand une page pleine ne fait pas avancer la date du dernier flux lu" do
    platform = S.platform
    platform.cursorless = true
    4.times { |index| platform.deliver(S.ubl_invoice("FM-#{index}"), "f#{index}.xml", "UBL") }
    same = Time.utc
    platform.flows.each(&.updated_at=(same))
    connector = derived
    cursor = nil
    pages = 0
    10.times do
      page = connector.fetch_incoming(cursor)
      pages += 1
      cursor = page.cursor
      break unless page.has_more
    end
    pages.should eq(2)
  end
end
