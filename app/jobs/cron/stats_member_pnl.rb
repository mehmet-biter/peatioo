module Jobs::Cron
  class StatsMemberPnl
    Error = Class.new(StandardError)

    class <<self
      def process_currency(pnl_currency, currency, batch_size=1000)
        queries = []
        idx = last_idx(pnl_currency, currency)

        query = "
        SELECT 'Trade', id, updated_at as ts FROM trades WHERE id > #{idx['Trade']} UNION
        SELECT 'Adjustment', id, updated_at as ts FROM adjustments WHERE updated_at > '#{idx['Adjustment']}' AND currency_id = '#{currency.id}' AND state = 2 UNION
        SELECT 'Transfer', id, updated_at as ts FROM transfers WHERE id > #{idx['Transfer']} UNION
        SELECT 'Withdraw', id, completed_at as ts FROM withdraws WHERE completed_at > '#{idx['Withdraw']}' AND currency_id = '#{currency.id}' AND aasm_state = 'succeed' UNION
        SELECT 'Deposit', id, created_at as ts FROM deposits WHERE created_at > '#{idx['DepositCoin']}' AND currency_id = '#{currency.id}' AND type = 'Deposits::Coin' UNION
        SELECT 'Deposit', id, completed_at as ts FROM deposits WHERE completed_at > '#{idx['DepositFiat']}' AND currency_id = '#{currency.id}' AND type = 'Deposits::Fiat' AND aasm_state = 'accepted'
        ORDER BY ts,id ASC LIMIT #{batch_size};"

        trade_idx = adjustment_idx = transfer_idx = withdraw_idx = deposit_fiat_idx = deposit_coin_idx = nil

        ActiveRecord::Base.connection.select_all(query).rows.each do |r|
            Rails.logger.info { "Processing: #{r[0]} #{r[1]} (#{pnl_currency.id} / #{currency.id})" }
            case r[0]
              when 'Adjustment'
                adjustment = Adjustment.find(r[1])
                adjustment_idx = (adjustment.updated_at.to_f * 1000).to_i + 1
                queries += process_adjustment(pnl_currency, adjustment)
              when 'Deposit'
                deposit = Deposit.find(r[1])
                queries += process_deposit(pnl_currency, deposit)
                case deposit
                when Deposits::Fiat
                  deposit_fiat_idx = (deposit.completed_at.to_f * 1000).to_i + 1
                when Deposits::Coin
                  deposit_coin_idx = (deposit.created_at.to_f * 1000).to_i + 1
                end
              when 'Trade'
                trade = Trade.find(r[1])
                trade_idx = trade.id
                buy_order = trade.buy_order
                sell_order = trade.sell_order
                queries += process_trade(pnl_currency, currency, trade, buy_order)
                queries += process_trade(pnl_currency, currency, trade, sell_order)
              when 'Withdraw'
                withdraw = Withdraw.find(r[1])
                withdraw_idx = (withdraw.completed_at.to_f * 1000).to_i + 1
                queries += process_withdraw(pnl_currency, withdraw)
              when 'Transfer'
                queries += process_transfer(pnl_currency, currency, r[1])
                transfer_idx = r[1]
            end
        end
        l_count = queries.size

        queries << build_query_idx(pnl_currency, currency.id, 'Adjustment', adjustment_idx) if adjustment_idx
        queries << build_query_idx(pnl_currency, currency.id, 'DepositFiat', deposit_fiat_idx) if deposit_fiat_idx
        queries << build_query_idx(pnl_currency, currency.id, 'DepositCoin', deposit_coin_idx) if deposit_coin_idx
        queries << build_query_idx(pnl_currency, currency.id, 'Trade', trade_idx) if trade_idx
        queries << build_query_idx(pnl_currency, currency.id, 'Withdraw', withdraw_idx) if withdraw_idx
        queries << build_query_idx(pnl_currency, currency.id, 'Transfer', transfer_idx) if transfer_idx

        update_pnl(queries) unless queries.empty?

        l_count
      end

      def last_idx(pnl_currency, currency)
        query = "SELECT reference_type, last_id FROM stats_member_pnl_idx WHERE currency_id = '#{currency.id}' AND pnl_currency_id = '#{pnl_currency.id}'"
        h = {
          "Trade" => 0,
          "DepositFiat" => "1970-01-01 00:00:00.000",
          "DepositCoin" => "1970-01-01 00:00:00.000",
          "Withdraw" => "1970-01-01 00:00:00.000",
          "Adjustment" => "1970-01-01 00:00:00.000",
          "Transfer" => 0,
        }
        ActiveRecord::Base.connection.select_all(query).rows.each do |name, idx|
          case name
          when /^(Deposit|Withdraw|Adjustment)/
            h[name] = Time.at(idx.to_f / 1000).utc.strftime("%F %T.%3N")
          else
            h[name] = idx
          end
        end
        h
      end

      def pnl_currencies
        @pnl_currencies ||= ENV.fetch('PNL_CURRENCIES', '').split(',').map {|id| Currency.find(id) }
      end

      def conversion_paths
        @conversion_paths ||= parse_conversion_paths(ENV.fetch('CONVERSION_PATHS', ''))
      end

      def parse_conversion_paths(str)
        paths = {}
        str.to_s.split(';').each do |path|
          raise 'Failed to parse CONVERSION_PATHS' if path.count(':') != 1

          mid, markets = path.split(':')
          raise 'Failed to parse CONVERSION_PATHS' if mid.empty? || mid.count('/') != 1

          paths[mid] = markets.split(',').map do |m|
            a, b = m.split('/')
            raise 'Failed to parse CONVERSION_PATHS' if a.to_s.empty? || b.to_s.empty?
            reverse = false
            if a.start_with?('_')
              reverse = true
              a = a[1..-1]
            end
            [a, b, reverse]
          end
        end
        paths
      end

      def conversion_market(currency_id, pnl_currency_id)
        market = Market.find_by(base_unit: currency_id, quote_unit: pnl_currency_id)
        raise Error, "There is no market #{currency_id}/#{pnl_currency_id}" unless market.present?

        market.id
      end

      def price_at(currency_id, pnl_currency_id, at)
        return 1.0 if currency_id == pnl_currency_id

        if (path = conversion_paths["#{currency_id}/#{pnl_currency_id}"])
          return path.reduce(1) do |price, (a, b, reverse)|
            if reverse
              price / price_at(a, b, at)
            else
              price * price_at(a, b, at)
            end
          end
        end

        market = conversion_market(currency_id, pnl_currency_id)
        nearest_trade = Trade.nearest_trade_from_influx(market, at)
        Rails.logger.debug { "Nearest trade on #{market} trade: #{nearest_trade}" }
        raise Error, "There is no trades on market #{market}" unless nearest_trade.present?

        nearest_trade[:price]
      end

      def process_trade(pnl_currency, currency, trade, order)
        queries = []
        Rails.logger.info { "Process trade: #{trade.id}" }
        market = trade.market
        return [] unless [market.quote_unit, market.base_unit].include?(currency.id)
        if order.side == 'buy'
          total_credit_fees = trade.amount * trade.order_fee(order)
          total_credit = trade.amount - total_credit_fees
          total_debit = trade.total
        else
          total_credit_fees = trade.total * trade.order_fee(order)
          total_credit = trade.total - total_credit_fees
          total_debit = trade.amount
        end

        if market.quote_unit == pnl_currency.id
          # Using trade price (direct conversion)
          if order.income_currency.id == currency.id
            order.side == 'buy' ? total_credit_value = total_credit * trade.price : total_credit_value = total_credit
            queries << build_query(order.member_id, pnl_currency, order.income_currency.id, total_credit, total_credit_fees, total_credit_value, 0, 0, 0)
          end

          if order.outcome_currency.id == currency.id
            order.side == 'buy' ? total_debit_value = total_debit : total_debit_value = total_debit * trade.price
            queries << build_query(order.member_id, pnl_currency, order.outcome_currency.id, 0, 0, 0, total_debit, total_debit_value, 0)
          end
        else
          # User last market price
          if order.income_currency.id == currency.id
            total_credit_value = (total_credit) * price_at(order.income_currency.id, pnl_currency.id, trade.created_at)
            queries << build_query(order.member_id, pnl_currency, order.income_currency.id, total_credit, total_credit_fees, total_credit_value, 0, 0, 0)
          end

          if order.outcome_currency.id == currency.id
            total_debit_value = (total_debit) * price_at(order.outcome_currency.id, pnl_currency.id, trade.created_at)
            queries << build_query(order.member_id, pnl_currency, order.outcome_currency.id, 0, 0, 0, total_debit, total_debit_value, 0)
          end
        end
        queries
      end

      def process_adjustment(pnl_currency, adjustment)
        Rails.logger.info { "Process adjustment: #{adjustment.id}" }
        if adjustment.amount < 0
          total_credit = total_credit_value = 0
          total_debit = -adjustment.amount
          total_debit_value = total_debit * price_at(adjustment.currency_id, pnl_currency.id, adjustment.created_at)
        else
          total_debit = total_debit_value = 0
          total_credit = adjustment.amount
          total_credit_value = total_credit * price_at(adjustment.currency_id, pnl_currency.id, adjustment.created_at)
        end
        account_number_hash = Operations.split_account_number(account_number: adjustment.receiving_account_number)
        member = Member.find_by(uid: account_number_hash[:member_uid]) if account_number_hash.key?(:member_uid)
        [
          build_query(member.id, pnl_currency, adjustment.currency_id, total_credit, 0.0, total_credit_value, total_debit, total_debit_value, 0),
        ]
      end

      def process_deposit(pnl_currency, deposit)
        Rails.logger.info { "Process deposit: #{deposit.id}" }
        total_credit = deposit.amount
        total_credit_fees = deposit.fee
        total_credit_value = total_credit * price_at(deposit.currency_id, pnl_currency.id, deposit.created_at)

        [build_query(deposit.member_id, pnl_currency, deposit.currency_id, total_credit, total_credit_fees, total_credit_value, 0, 0, 0)]
      end

      def process_withdraw(pnl_currency, withdraw)
        Rails.logger.info { "Process withdraw: #{withdraw.id}" }
        total_debit = withdraw.amount
        total_debit_fees = withdraw.fee
        total_debit_value = (total_debit + total_debit_fees) * price_at(withdraw.currency_id, pnl_currency.id, withdraw.created_at)

        [
          build_query(withdraw.member_id, pnl_currency, withdraw.currency_id, 0, 0, 0, total_debit, total_debit_value, total_debit_fees),
        ]
      end

      def process_transfer(pnl_currency, currency, reference_id)
        transfer = {}
        queries = []

        q = "SELECT currency_id, member_id, reference_type, reference_id, SUM(credit-debit) as total FROM liabilities " \
        "WHERE reference_type = 'Transfer' AND reference_id = #{reference_id} " \
        "GROUP BY currency_id, member_id, reference_type, reference_id"
        liabilities = ActiveRecord::Base.connection.select_all(q)
        liabilities.each do |l|
          next if l['total'].zero?

          cid = l['currency_id']
          transfer[cid] ||= {
            type: nil,
            liabilities: []
          }

          transfer[cid][:liabilities] << l
        end

        case transfer.size # number of currencies in the transfer
        when 0
        when 1
          # Probably a lock transfer, ignoring

        when 2
          # We have 2 currencies exchanged, so we can calculate a price
          store = Hash.new do |member_store, mid|
            member_store[mid] = Hash.new do |h, k|
              h[k] = {
                total_debit_fees: 0,
                total_credit_fees: 0,
                total_credit: 0,
                total_debit: 0,
                total_amount: 0,
              }
            end
          end

          transfer.each do |cid, infos|
            Operations::Revenue.where(reference_type: 'Transfer', reference_id: reference_id, currency_id: cid).each do |fee|
              store[fee.member_id][cid][:total_debit_fees] += fee.credit
              store[fee.member_id][cid][:total_debit] -= fee.credit
              # We don't support fees payed on credit, they are all considered debit fees
            end

            byebug if infos.nil?
            infos[:liabilities].each do |l|
              store[l['member_id']] ||= {}
              store[l['member_id']][cid]

              if l['total'].positive?
                store[l['member_id']][cid][:total_credit] += l['total']
                store[l['member_id']][cid][:total_amount] += l['total']
              else
                store[l['member_id']][cid][:total_debit] -= l['total']
                store[l['member_id']][cid][:total_amount] -= l['total']
              end
            end
          end

          def price_of_transfer(a_total, b_total)
            b_total / a_total
          end

          store.each do |member_id, stats|
            a, b = stats.keys

            if a == pnl_currency.id
              b, a = stats.keys
            elsif b != pnl_currency.id
              raise 'Need direct conversion for transfers'
            end
            next if stats[b][:total_amount].zero?

            price = price_of_transfer(stats[a][:total_amount], stats[b][:total_amount])

            a_total_credit_value = stats[a][:total_credit] * price
            b_total_credit_value = stats[b][:total_credit]

            a_total_debit_value = stats[a][:total_debit] * price
            b_total_debit_value = stats[b][:total_debit]

            if a == currency.id
              queries << build_query(member_id, pnl_currency, a, stats[a][:total_credit], stats[a][:total_credit_fees], a_total_credit_value, stats[a][:total_debit], a_total_debit_value, stats[a][:total_debit_fees])
            end
            if b == currency.id
              queries << build_query(member_id, pnl_currency, b, stats[b][:total_credit], stats[b][:total_credit_fees], b_total_credit_value, stats[b][:total_debit], b_total_debit_value, stats[b][:total_debit_fees])
            end
          end

        else
          raise 'Transfers with more than 2 currencies brakes pnl calculation'
        end
        queries
      end

      def process
        l_count = 0
        @sleep_until ||= {}
        pnl_currencies.each do |pnl_currency|
          Currency.visible.each do |currency|
            begin
              ts = @sleep_until[[pnl_currency.id, currency.id]]
              if ts.nil? || ts < Time.now.to_i
                l_count += process_currency(pnl_currency, currency)
              end
            rescue StandardError => e
              Rails.logger.error("Failed to process currency #{pnl_currency.id}/#{currency.id}: #{e}: #{e.backtrace.join("\n")}")
              @sleep_until[[pnl_currency.id, currency.id]] = Time.now.to_i + 300
              # TODO: Count the error in prometheus for this currency
            end
          end
        end

        sleep 3 if l_count == 0
      end

      def build_query_idx(pnl_currency, currency_id, reference_type, idx)
        "REPLACE INTO stats_member_pnl_idx (pnl_currency_id, currency_id, reference_type, last_id) " \
        "VALUES ('#{pnl_currency.id}','#{currency_id}','#{reference_type}',#{idx})"
      end

      def build_query(member_id, pnl_currency, currency_id, total_credit, total_credit_fees, total_credit_value, total_debit, total_debit_value, total_debit_fees)
        if pnl_currency.id == currency_id
          average_balance_price = 1
          avg_balance_formula = '1'
        else
          average_balance_price = total_credit.zero? ? 0 : (total_credit_value / total_credit)
          balance_formula = '(VALUES(total_credit) + total_credit - total_debit - total_debit_fees)'
          avg_balance_formula = "IF(VALUES(total_credit)=0 OR #{balance_formula}<=0 OR total_balance_value < 0, average_balance_price, total_balance_value/#{balance_formula})"
        end

        'INSERT INTO stats_member_pnl (member_id, pnl_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, total_debit, total_debit_value, total_debit_fees, total_balance_value, average_balance_price) ' \
        "VALUES (#{member_id},'#{pnl_currency.id}','#{currency_id}',#{total_credit},#{total_credit_fees},#{total_credit_value},#{total_debit},#{total_debit_value},#{total_debit_fees},#{total_credit_value},#{average_balance_price}) " \
        'ON DUPLICATE KEY UPDATE ' \
        'total_balance_value = GREATEST(0, total_balance_value + VALUES(total_balance_value) - IF(VALUES(total_debit) = 0, 0, (VALUES(total_debit) + VALUES(total_debit_fees)) * average_balance_price)), ' \
        "average_balance_price = #{avg_balance_formula}, " \
        'total_credit = total_credit + VALUES(total_credit), ' \
        'total_credit_fees = total_credit_fees + VALUES(total_credit_fees), ' \
        'total_debit_fees = total_debit_fees + VALUES(total_debit_fees), ' \
        'total_credit_value = total_credit_value + VALUES(total_credit_value), ' \
        'total_debit_value = total_debit_value + VALUES(total_debit_value), ' \
        'total_debit = total_debit + VALUES(total_debit), ' \
        'updated_at = NOW()'
      end

      def update_pnl(queries)
        ActiveRecord::Base.connection.transaction do
          queries.each do |query|
            ActiveRecord::Base.connection.exec_query(query)
          end
        end
      end
    end
  end
end
