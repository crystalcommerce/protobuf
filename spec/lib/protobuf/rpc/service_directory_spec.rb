require 'spec_helper'

require 'protobuf/rpc/service_directory'

describe ::Protobuf::Rpc::ServiceDirectory do
  let(:instance) { ::Protobuf::Rpc::ServiceDirectory.instance }

  def listings
    instance.instance_variable_get(:@listings)
  end

  def duration
    start = Time.now.to_f
    yield
    Time.now.to_f - start
  end

  after do
    instance.stop
  end

  it "is a singleton" do
    instance.should be_a_kind_of(Singleton)
  end

  describe "#lookup" do
    let(:server) { double('server', :uuid => '123',
                          :services => ['Known::Service'],
                          :address => "0.0.0.0",
                          :port => 9999,
                          :ttl => 15) }
    let(:listing) { ::Protobuf::Rpc::ServiceDirectory::Listing.new(server) }

    it "returns a listing for the given service" do
      instance.add_listing_for(server)
      instance.lookup("Known::Service").should eq listing
    end

    it "returns random listings" do
      instance.add_listing_for double(:uuid => 1, :ttl => 5, :services => ["Test"])
      instance.add_listing_for double(:uuid => 2, :ttl => 5, :services => ["Test"])

      uuids = 100.times.map { instance.lookup("Test").uuid }
      uuids.count(1).should be_within(25).of(50)
      uuids.count(2).should be_within(25).of(50)
    end

    it "does not return expired listings" do
      instance.instance_variable_set(:@listings, {
        '1' => double(:current? => false, :services => ["Test"]),
      })

      instance.lookup("Test").should be_nil
    end
  end

  describe "#remove_expired_listings" do
    before do
      instance.instance_variable_set(:@listings, {
        '1' => double(:expired? => true),
        '2' => double(:expired? => true),
        '3' => double(:expired? => false),
      })
    end

    it "removes expired listings" do
      expect {
        instance.remove_expired_listings
      }.to change(listings, :size).from(3).to(1)
      listings.keys.should eq ['3']
    end
  end

  describe "#start" do
    it "creates a thread" do
      Thread.should_receive(:new)
      instance.start
    end

    it "initializes the socket" do
      instance.should_receive :init_socket
      instance.start
    end

    it "calls #run" do
      instance.should_receive(:run)
      instance.start
      sleep 0.01
    end

    it "changes the running state" do
      expect {
        instance.start
      }.to change(instance, :running?).from(false).to(true)
    end
  end

  describe "#wait_for" do
    it "returns a listing for the given service" do
      server = double(:uuid => 1, :ttl => 5, :services => ["Test"])
      instance.add_listing_for server
      instance.lookup("Test").should eq server
    end

    it "depends on #lookup" do
      instance.stub(:lookup).with("Hayoob!") { "yup" }
      instance.wait_for("Hayoob!").should eq "yup"
    end

    it "waits for the service to appear" do
      server = double(:uuid => 1, :ttl => 5, :services => ["Test"])

      t = Thread.new do
        sleep 0.5
        instance.add_listing_for server
      end

      duration { instance.wait_for("Test") }.should be_within(0.01).of(0.5)
      t.join
    end

    it "returns nil if the service doesn't appear withint the timeout period" do
      server = double(:uuid => 1, :ttl => 5, :services => ["Test"])

      t = Thread.new do
        sleep 0.5
        instance.add_listing_for server
      end

      instance.wait_for("Test", 0.1).should be_nil
      t.join
    end
  end

  describe "a running service directory" do
    let(:socket) { UDPSocket.new }

    def thread
      instance.instance_variable_get(:@thread)
    end

    before do
      described_class.start do |config|
        config.address = "127.0.0.1"
        config.port = 33333
      end

      socket.connect described_class.address, described_class.port
    end

    context "receiving a heartbeat" do
      let(:server) { ::Protobuf::Rpc::DynamicDiscovery::Server.new(:uuid => 'heartbeat', :address => '127.0.0.1') }
      let(:beacon) { ::Protobuf::Rpc::DynamicDiscovery::Beacon.new(
        :server => server,
        :beacon_type => ::Protobuf::Rpc::DynamicDiscovery::BeaconType::HEARTBEAT
      )}
      let(:payload) { beacon.serialize_to_string }

      it "adds a listing" do
        instance.should_receive(:add_listing_for).with(server)
        instance.should_receive(:remove_expired_listings)
        socket.send(payload, 0)
        sleep 0.01
      end
    end

    context "receiving a flatline" do
      let(:server) { ::Protobuf::Rpc::DynamicDiscovery::Server.new(:uuid => 'flatline', :address => '127.0.0.1') }
      let(:beacon) { ::Protobuf::Rpc::DynamicDiscovery::Beacon.new(
        :server => server,
        :beacon_type => ::Protobuf::Rpc::DynamicDiscovery::BeaconType::FLATLINE
      )}
      let(:payload) { beacon.serialize_to_string }

      it "removes a listing" do
        instance.should_receive(:remove_listing_for).with(server)
        instance.should_receive(:remove_expired_listings)
        socket.send(payload, 0)
        sleep 0.01
      end
    end
  end
end
