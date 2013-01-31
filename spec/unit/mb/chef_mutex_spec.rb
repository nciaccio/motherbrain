require 'spec_helper'

describe MB::ChefMutex do
  subject { chef_mutex }

  let(:chef_mutex) { klass.new(options.merge lockset) }

  let(:client_name) { "johndoe" }
  let(:lockset) { { chef_environment: "my_environment" } }
  let(:options) { Hash.new }

  let(:chef_connection_stub) { stub client_name: client_name }
  let(:locks_stub) { stub(
      delete: true,
      find: nil,
      new: stub(save: true)
  ) }

  before do
    chef_mutex.stub locks: locks_stub
    chef_mutex.stub externally_testing?: false
  end

  its(:type) { should == lockset.keys.first }
  its(:name) { should == lockset.values.first }

  its(:to_s) { should == "#{chef_mutex.type}:#{chef_mutex.name}" }
  its(:data_bag_id) { should == "#{chef_mutex.type}-#{chef_mutex.name}" }

  describe "#lock" do
    subject(:lock) { chef_mutex.lock }

    it "attempts a lock" do
      chef_mutex.should_receive :attempt_lock

      lock
    end

    context "with no existing lock" do
      before { chef_mutex.stub read: false, write: true }

      it { should be_true }

      context "and the lock attempt fails" do
        before { chef_mutex.stub write: false }

        it { should be_false }
      end
    end

    context "with an existing lock" do
      before { chef_mutex.stub read: {}, write: true }

      it { should be_false }

      context "and force enabled" do
        let(:options) { { force: true } }

        it { should be_true }
      end
    end

    context "without a valid lock type" do
      let(:lockset) { { something: "something" } }

      it { -> { lock }.should raise_error MB::InvalidLockType }
    end

    context "when passed a job" do
      let(:job_stub) { stub }
      let(:options) { { job: job_stub } }

      it "sets the job status" do
        job_stub.should_receive(:status=).with(
          "Locking chef_environment:my_environment"
        )

        lock
      end
    end
  end

  describe "#synchronize" do
    subject(:synchronize) { chef_mutex.synchronize(&test_block) }

    TestProbe = Object.new

    let(:test_block) { -> { TestProbe.testing } }

    before do
      chef_mutex.stub lock: true, unlock: true

      TestProbe.stub :testing
    end

    it "runs the block" do
      TestProbe.should_receive :testing

      synchronize
    end

    it "obtains a lock" do
      chef_mutex.should_receive :lock

      synchronize
    end

    it "releases the lock" do
      chef_mutex.should_receive :unlock

      synchronize
    end

    context "when the lock is unobtainable" do
      before do
        chef_mutex.stub lock: false, read: {}
      end

      it "does not attempt to release the lock" do
        chef_mutex.should_not_receive :unlock

        synchronize
      end

      context "and force enabled" do
        let(:options) { { force: true } }

        it "locks with force" do
          chef_mutex.should_receive(:lock).and_return(true)

          synchronize
        end
      end
    end

    context "on block failure" do
      before do
        TestProbe.stub(:testing).and_raise(RuntimeError)
      end

      it "raises the error" do
        -> { synchronize }.should raise_error RuntimeError
      end

      it "releases the lock" do
        chef_mutex.should_receive :unlock

        -> { synchronize }.should raise_error RuntimeError
      end

      context "and passed unlock_on_failure: false" do
        before do
          options[:unlock_on_failure] = false
        end

        it "does not release the lock" do
          chef_mutex.should_not_receive :unlock

          -> { synchronize }.should raise_error RuntimeError
        end
      end
    end
  end

  describe "#unlock" do
    subject(:unlock) { chef_mutex.unlock }

    it "attempts an unlock" do
      chef_mutex.should_receive :attempt_unlock

      unlock
    end

    context "when passed a job" do
      let(:job_stub) { stub }
      let(:options) { { job: job_stub } }

      it "sets the job status" do
        job_stub.should_receive(:status=).with(
          "Unlocking chef_environment:my_environment"
        )

        unlock
      end
    end
  end

  describe "#our_lock?" do
    before do
      chef_mutex.class.class_eval { public :our_lock? }
      chef_mutex.stub(:client_name).and_return("johndoe")
    end

    after do
      chef_mutex.class.class_eval { private :our_lock? }
    end

    subject(:our_lock?) { chef_mutex.our_lock?(current_lock) }
    let(:current_lock) { { id: "_chef_environment_:my_environment"} }

    context "when current_lock is not from our client" do
      before { current_lock['client_name'] = "janedoe" }

      it { should be_false }
    end

    context "when current_lock is from our client" do
      before { current_lock['client_name'] = "johndoe" }

      context "when process_id is our process" do
        before do
          Process.stub(:pid).and_return(12345)
          current_lock['process_id'] = 12345
        end
        it { should be_true }
      end

      context "when process_id is not our process" do
        before do
          Process.stub(:pid).and_return(12345)
          current_lock['process_id'] = 23456
        end
        it { should be_false }
      end
    end
  end
end
