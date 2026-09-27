# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./connector"
require "./http"
require "./models/**"
require "./formats/**"
require "./services/**"
require "./connectors/**"
require "./api/**"

# Extension EINV de Partiduo : facturation électronique (ADR-004), successeur
# de `peppol-connect` de NOALYSS. Même plan qu'une application du cœur
# (DECISIONS C1) : `manifest.cr`, `models/`, `migrations/`, `services/`
# (interne), `api/` (contrat public `Einvoicing::Api`), `locales/` ; en plus
# `connector.cr` (connecteur abstrait de plateforme agréée, ADR-004 D2),
# `connectors/` (adaptateurs XP Z12-013 et NOALYSS-PEPPOL) et `formats/`
# (CII, UBL, Factur-X, CDAR, e-reporting).
module Einvoicing
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `einv` dans `PARTIDUO_MODULES`.
  CODE = "EINV"

  # Application Marten du métier : modèles (tables `einvoicing_*`),
  # migrations et libellés.
  class App < Marten::App
    label "einvoicing"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Document::INSTALLED_APPS`.
  INSTALLED_APPS = [Einvoicing::App] of Marten::Apps::Config.class
end
