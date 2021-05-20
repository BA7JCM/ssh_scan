require 'socket'
require 'ssh_scan/client'
require 'ssh_scan/public_key'
require 'ssh_scan/fingerprint_database'
require 'ssh_scan/subprocess'
require 'ssh_scan/ssh_fp'
require 'net/ssh'
require 'logger'
require 'open3'

module SSHScan
  # Handle scanning of targets.
  class ScanEngine

    # Scan a single target.
    # @param socket [String] ip:port specification
    # @param opts [Hash] options (timeout, ...)
    # @return [Hash] result
    def scan_target(socket, opts)
      target, port = socket.chomp.split(':')
      if port.nil?
        port = 22
      end

      timeout = opts["timeout"]
      
      result = SSHScan::Result.new()
      result.port = port.to_i

      # Start the scan timer
      result.set_start_time

      if target.fqdn?
        result.hostname = target

        # If doesn't resolve as IPv6, we'll try IPv4
        if target.resolve_fqdn_as_ipv6.nil?
          client = SSHScan::Client.new(
            target.resolve_fqdn_as_ipv4.to_s, port, timeout
          )
          client.connect
          result.set_client_attributes(client)
          kex_result = client.get_kex_result()
          client.close
          result.set_kex_result(kex_result) unless kex_result.nil?
          result.error = client.error if client.error?
        # If it does resolve as IPv6, we're try IPv6
        else
          client = SSHScan::Client.new(
            target.resolve_fqdn_as_ipv6.to_s, port, timeout
          )
          client.connect
          result.set_client_attributes(client)
          kex_result = client.get_kex_result()
          client.close
          result.set_kex_result(kex_result) unless kex_result.nil?
          result.error = client.error if client.error?

          # If resolves as IPv6, but somehow we get an client error, fall-back to IPv4
          if result.error?
            result.unset_error
            client = SSHScan::Client.new(
              target.resolve_fqdn_as_ipv4.to_s, port, timeout
            )
            client.connect()
            result.set_client_attributes(client)
            kex_result = client.get_kex_result()
            client.close
            result.set_kex_result(kex_result) unless kex_result.nil?
            result.error = client.error if client.error?
          end
        end
      else
        client = SSHScan::Client.new(target, port, timeout)
        client.connect()
        result.set_client_attributes(client)
        kex_result = client.get_kex_result()
        client.close

        unless kex_result.nil?
          result.set_kex_result(kex_result)
        end

        # Attempt to suppliment a hostname that wasn't provided
        result.hostname = target.resolve_ptr

        result.error = client.error if client.error?
      end

      if result.error?
        result.set_end_time
        return result
      end

      # Connect and get results (Net-SSH)
      begin
        net_ssh_session = Net::SSH::Transport::Session.new(
                            target,
                            :port => port,
                            :timeout => timeout,
                            :verify_host_key => :never
                          )
        raise SSHScan::Error::ClosedConnection.new if net_ssh_session.closed?
        auth_session = Net::SSH::Authentication::Session.new(
          net_ssh_session, :auth_methods => ["none"]
        )
        auth_session.authenticate("none", "test", "test")
        result.auth_methods = auth_session.allowed_auth_methods
        net_ssh_session.close
      rescue Net::SSH::ConnectionTimeout => e
        result.error = SSHScan::Error::ConnectTimeout.new(e.message)
      rescue Net::SSH::Disconnect, Errno::ECONNRESET => e
        result.error = SSHScan::Error::Disconnected.new(e.message)
      rescue Net::SSH::Exception => e
        if e.to_s.match(/could not settle on/)
          result.error = e
        else
          raise e
        end
      end

      # Figure out what rsa or dsa fingerprints exist
      keys = {}

      output = ""

      cmd = ['ssh-keyscan', '-t', 'rsa,dsa,ecdsa,ed25519', '-p', port.to_s, target].join(" ")

      Utils::Subprocess.new(cmd) do |stdout, stderr, thread|
        if stdout
          output += stdout
        end
      end

      host_keys = output.split
      host_keys_len = host_keys.length - 1

      for i in 0..host_keys_len
        if host_keys[i].eql? "ssh-dss"
          key = SSHScan::Crypto::PublicKey.new([host_keys[i], host_keys[i + 1]].join(" "))
          keys.merge!(key.to_hash)
        end

        if host_keys[i].eql? "ssh-rsa"
          key = SSHScan::Crypto::PublicKey.new([host_keys[i], host_keys[i + 1]].join(" "))
          keys.merge!(key.to_hash)
        end

        if host_keys[i].eql? "ecdsa-sha2-nistp256"
          key = SSHScan::Crypto::PublicKey.new([host_keys[i], host_keys[i + 1]].join(" "))
          keys.merge!(key.to_hash)
        end

        if host_keys[i].eql? "ssh-ed25519"
          key = SSHScan::Crypto::PublicKey.new([host_keys[i], host_keys[i + 1]].join(" "))
          keys.merge!(key.to_hash)
        end
      end

      result.keys = keys
      result.set_end_time

      return result
    end

    # Utilize multiple threads to scan multiple targets, combine
    # results and check for compliance.
    # @param opts [Hash] options (sockets, threads ...)
    # @return [Hash] results
    def scan(opts)
      sockets = opts["sockets"]
      threads = opts["threads"] || 5
      logger = opts["logger"] || Logger.new(STDOUT)

      results = []

      work_queue = Queue.new

      sockets.each {|x| work_queue.push x }
      workers = (0...threads).map do
        Thread.new do
          begin
            while socket = work_queue.pop(true)
              results << scan_target(socket, opts)
            end
          rescue ThreadError => e
            raise e unless e.to_s.match(/queue empty/)
          end
        end
      end
      workers.map(&:join)

      # Add all the fingerprints to our peristent FingerprintDatabase
      fingerprint_db = SSHScan::FingerprintDatabase.new(
        opts['fingerprint_database']
      )
      results.each do |result|
        fingerprint_db.clear_fingerprints(result.ip)

        if result.keys
          result.keys.values.each do |host_key_algo|
            host_key_algo['fingerprints'].values.each do |fingerprint|
              fingerprint_db.add_fingerprint(fingerprint, result.ip)
            end
          end
        end
      end

      # Decorate all the results with duplicate keys
      results.each do |result|
        if result.keys
          ip = result.ip
          result.duplicate_host_key_ips = []
          result.keys.values.each do |host_key_algo|
            host_key_algo["fingerprints"].values.each do |fingerprint|
              fingerprint_db.find_fingerprints(fingerprint).each do |other_ip|
                next if ip == other_ip
                result.duplicate_host_key_ips << other_ip
              end
            end
          end
        end
      end

      # Decorate all the results with SSHFP records
      sshfp = SSHScan::SshFp.new()
      results.each do |result|
        if !result.hostname.empty?
          dns_keys = sshfp.query(result.hostname)
          result.dns_keys = dns_keys
        end
      end

      # Decorate all the results with compliance information
      results.each do |result|
        # Do this only when we have all the information we need
        if opts["policy"] &&
           result.key_algorithms.any? &&
           result.server_host_key_algorithms.any? &&
           result.encryption_algorithms_client_to_server.any? &&
           result.encryption_algorithms_server_to_client.any? &&
           result.mac_algorithms_client_to_server.any? &&
           result.mac_algorithms_server_to_client.any? &&
           result.compression_algorithms_client_to_server.any? &&
           result.compression_algorithms_server_to_client.any?

          policy = SSHScan::Policy.from_file(opts["policy"])
          policy_mgr = SSHScan::PolicyManager.new(result, policy)
          result.set_compliance = policy_mgr.compliance_results

          if result.compliance_policy
            result.grade = SSHScan::Grader.new(result).grade
          end
        end
      end

      return results.map {|r| r.to_hash}
    end
  end
end
