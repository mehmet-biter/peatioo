# frozen_string_literal: true

describe Deposit do
  let(:member) { create(:member) }
  let(:amount) { 100.to_d }
  let(:deposit) { create(:deposit_usd, member: member, amount: amount, currency: currency) }
  let(:currency) { Currency.find(:usd) }

  it 'computes fee' do
    expect(deposit.fee).to eql 0.to_d
    expect(deposit.amount).to eql 100.to_d
  end

  context 'fee is set to fixed value of 10' do
    before { Currency.any_instance.expects(:deposit_fee).once.returns(10) }

    it 'computes fee' do
      expect(deposit.fee).to eql 10.to_d
      expect(deposit.amount).to eql 90.to_d
    end
  end

  context 'fee exceeds amount' do
    before { Currency.any_instance.expects(:deposit_fee).once.returns(1.1) }
    let(:amount) { 1 }
    let(:deposit) { build(:deposit_usd, member: member, amount: amount, currency: currency) }
    it 'fails validation' do
      expect(deposit.save).to eq false
      expect(deposit.errors.full_messages).to eq ['Amount must be greater than 0.0', 'Amount must be greater than or equal to 0.0']
    end
  end

  it 'automatically generates TID if it is blank' do
    expect(create(:deposit_btc).tid).not_to be_blank
  end

  it 'doesn\'t generate TID if it is not blank' do
    expect(create(:deposit_btc, tid: 'TID1234567890xyz').tid).to eq 'TID1234567890xyz'
  end

  it 'validates uniqueness of TID' do
    record1 = create(:deposit_btc)
    record2 = build(:deposit_btc, tid: record1.tid)
    record2.save
    expect(record2.errors.full_messages.first).to match(/tid has already been taken/i)
  end

  it 'uppercases automatically generated TID' do
    record = create(:deposit_btc)
    expect(record.tid).to eq record.tid.upcase
  end

  context 'calculates confirmations' do
    let(:deposit) { create(:deposit_btc) }

    it 'uses height from blockchain by default' do
      deposit.blockchain.stubs(:processed_height).returns(100)
      deposit.stubs(:block_number).returns(90)
      expect(deposit.confirmations).to eql(10)
    end
  end

  context :spread_between_wallets! do
    let(:spread) do
      [Peatio::Transaction.new(to_address: 'to-address-1', amount: 1.2),
       Peatio::Transaction.new(to_address: 'to-address-2', amount: 2.5)]
    end
    let(:deposit) { create(:deposit_btc, amount: 3.7) }

    before do
      WalletService.any_instance.expects(:spread_deposit).returns(spread)
    end

    it 'spreads deposit between wallets' do
      expect(deposit.spread).to eq([])
      expect(deposit.spread_between_wallets!).to be_truthy
      expect(deposit.reload.spread).to eq(spread.map(&:as_json).map(&:symbolize_keys))

      expect(deposit.spread_between_wallets!).to be_falsey
    end
  end

  context :accept do
    context :record_complete_operations! do
      subject { deposit }
      it 'creates single asset operation' do
        expect { subject.accept! }.to change { Operations::Asset.count }.by(1)
      end

      it 'credits assets with correct amount' do
        subject.accept!
        asset_operation = Operations::Asset.find_by(reference: subject)
        expect(asset_operation.credit).to eq(subject.amount)
      end

      it 'creates single liability operation' do
        expect { subject.accept! }.to change { Operations::Liability.count }.by(1)
      end

      it 'credits liabilities with correct amount' do
        subject.accept!
        liability_operation = Operations::Liability.find_by(reference: subject)
        expect(liability_operation.credit).to eq(subject.amount)
      end

      context 'zero deposit fee' do
        it 'doesn\'t create revenue operation' do
          expect { subject.accept! }.to_not change { Operations::Revenue.count }
        end
      end

      context 'greater than zero deposit fee' do
        let(:currency) do
          Currency.find(:usd).tap { |c| c.update(deposit_fee: 0.01) }
        end

        let(:deposit) do
          create(:deposit_usd, member: member, amount: amount, currency: currency)
        end

        it 'creates single revenue operation' do
          expect { subject.accept! }.to change { Operations::Revenue.count }.by(1)
        end

        it 'credits revenues with fee amount' do
          subject.accept!
          revenue_operation = Operations::Revenue.find_by(reference: subject)
          expect(revenue_operation.credit).to eq(subject.fee)
        end

        it 'creates revenue from member' do
          expect { subject.accept! }.to change { Operations::Revenue.where(member: member).count }.by(1)
        end
      end

      it 'credits both legacy and operations based member balance for fait deposit' do
        subject.accept!

        %i[main locked].each do |kind|
          expect(
            subject.member.balance_for(currency: subject.currency, kind: kind)
          ).to eq(
            subject.member.legacy_balance_for(currency: subject.currency, kind: kind)
          )
        end
      end

      context 'credits both legacy and operations based member balance for coin deposit' do
        subject { create(:deposit_btc, amount: 3.7) }
        it do
          subject.accept!
          %i[main locked].each do |kind|
            expect(
              subject.member.balance_for(currency: subject.currency, kind: kind)
            ).to eq(
              subject.member.legacy_balance_for(currency: subject.currency, kind: kind)
            )
          end
        end
      end
    end
  end

  context :process do
    let(:crypto_deposit) { create(:deposit_btc, amount: 3.7) }

    it 'doesnt process fiat deposit' do
      deposit.accept!
      expect(deposit.process!).to eq false
    end

    it 'process coin deposit' do
      crypto_deposit = create(:deposit_btc, amount: 3.7)
      crypto_deposit.accept!
      expect(crypto_deposit.process!).to eq true
      expect(crypto_deposit.processing?).to eq true
    end
  end


  context :processing do
    let(:crypto_deposit) { create(:deposit_btc, amount: 3.7) }

    before do
      crypto_deposit.accept!
      crypto_deposit.process!
    end

    subject { crypto_deposit }

    it 'commit deposit to collected' do
      # Minus locked and plus main accounts
      expect { subject.dispatch! }.to change { Operations::Liability.count }.by(2)

      %i[main locked].each do |kind|
        expect(
          subject.member.balance_for(currency: subject.currency, kind: kind)
        ).to eq(
          subject.member.legacy_balance_for(currency: subject.currency, kind: kind)
        )
      end
      expect(crypto_deposit.aasm_state).to eq('collected')
    end

    it 'dispatch deposit to skipped' do
      # Minus locked and plus main accounts
      expect { subject.skip! }.to change { Operations::Liability.count }.by(0)

      %i[main locked].each do |kind|
        expect(
          subject.member.balance_for(currency: subject.currency, kind: kind)
        ).to eq(
          subject.member.legacy_balance_for(currency: subject.currency, kind: kind)
        )
      end
      expect(crypto_deposit.aasm_state).to eq('skipped')
    end
  end
  context :dispatch do
    let(:crypto_deposit) { create(:deposit_btc, amount: 3.7) }

    before do
      crypto_deposit.accept!
      crypto_deposit.process!
    end

    subject { crypto_deposit }
    it 'dispatches deposit' do
      subject.dispatch!

      %i[main locked].each do |kind|
        expect(
          subject.member.balance_for(currency: subject.currency, kind: kind)
        ).to eq(
          subject.member.legacy_balance_for(currency: subject.currency, kind: kind)
        )
      end
    end
  end
end