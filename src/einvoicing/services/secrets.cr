# SPDX-License-Identifier: AGPL-3.0-or-later

require "openssl"
require "openssl/hmac"
require "base64"
require "crypto/subtle"

module Einvoicing
  # Chiffrement des secrets et jetons de la plateforme agréée en base
  # (ADR-004 D2, ADR-003 D6) : AES-256-CBC, vecteur aléatoire, puis
  # HMAC-SHA-256 du tout (chiffrer puis authentifier). Format :
  # `v1:<base64(iv ‖ chiffré ‖ mac)>`.
  #
  # Clé : `PARTIDUO_EINVOICING_KEY` (64 caractères hexadécimaux) si elle est
  # définie, sinon dérivée de la clé secrète de l'instance
  # (`Marten.settings.secret_key`, `MARTEN_SECRET_KEY` en production) ; deux
  # sous-clés distinctes pour le chiffrement et l'authentification
  # (DECISIONS D-EINV-004). Le cœur n'expose pas de service de secrets : il
  # est ici, interne à l'extension.
  module Secrets
    PREFIX = "v1:"

    class Error < Exception
    end

    def self.encrypt(plain : String) : String
      return "" if plain.empty?
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      cipher.key = encryption_key
      iv = Random::Secure.random_bytes(16)
      cipher.iv = iv
      io = IO::Memory.new
      io.write(iv)
      io.write(cipher.update(plain.to_slice))
      io.write(cipher.final)
      body = io.to_slice
      mac = OpenSSL::HMAC.digest(:sha256, mac_key, body)
      PREFIX + Base64.strict_encode(Bytes.new(body.size + mac.size).tap do |all|
        body.copy_to(all)
        mac.copy_to(all + body.size)
      end)
    end

    # Texte clair ; lève `Error` si la valeur a été altérée ou chiffrée avec
    # une autre clé.
    def self.decrypt(value : String) : String
      return "" if value.empty?
      raise Error.new("format de secret inconnu") unless value.starts_with?(PREFIX)
      all = Base64.decode(value.lchop(PREFIX))
      raise Error.new("secret tronqué") if all.size < 16 + 16 + 32
      body, mac = all[0, all.size - 32], all[all.size - 32, 32]
      unless Crypto::Subtle.constant_time_compare(OpenSSL::HMAC.digest(:sha256, mac_key, body), mac)
        raise Error.new("secret altéré ou clé différente")
      end
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = encryption_key
      cipher.iv = body[0, 16]
      io = IO::Memory.new
      io.write(cipher.update(body + 16))
      io.write(cipher.final)
      String.new(io.to_slice)
    rescue ex : Base64::Error
      raise Error.new("secret illisible : #{ex.message}")
    end

    def self.encrypt_json(values : Hash(String, String)) : String
      values.empty? ? "" : encrypt(values.to_json)
    end

    def self.decrypt_json(value : String) : Hash(String, String)
      return {} of String => String if value.empty?
      Hash(String, String).from_json(decrypt(value))
    end

    private def self.master : Bytes
      if (hex = ENV["PARTIDUO_EINVOICING_KEY"]?) && hex.matches?(/\A[0-9a-fA-F]{64}\z/)
        hex.hexbytes
      else
        OpenSSL::Digest.new("SHA256").update("partiduo-einvoicing:#{Marten.settings.secret_key}").final
      end
    end

    private def self.encryption_key : Bytes
      OpenSSL::HMAC.digest(:sha256, master, "encryption")
    end

    private def self.mac_key : Bytes
      OpenSSL::HMAC.digest(:sha256, master, "authentication")
    end
  end
end
