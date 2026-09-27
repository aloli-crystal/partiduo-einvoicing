# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

# Composition d'une distribution : l'interface (qui charge le cœur), le
# métier de DOCUMENT et de l'extension, leurs interfaces Bulma, puis les
# réglages.
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-einvoicing"
require "partiduo-document/ui/bulma"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
# Migrations du cœur, de DOCUMENT et de l'extension.
require "partiduo/cli"
require "partiduo-document/cli"
require "../src/partiduo-einvoicing/cli"

require "marten/spec"
require "marten_auth/spec"

# Comptes, navigateur et dossier de test de l'interface, créés par le
# contrat `Partiduo::Api` (DECISIONS D-SKEL-004).
require "../lib/partiduo-ui-bulma/spec/support/accounts"
require "../lib/partiduo-ui-bulma/spec/support/browser"
require "../lib/partiduo-ui-bulma/spec/support/reference"
require "../lib/partiduo-ui-bulma/spec/support/books"

require "./support/**"
