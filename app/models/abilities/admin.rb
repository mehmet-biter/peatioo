# encoding: UTF-8
# frozen_string_literal: true

module Abilities
  class Admin
    include CanCan::Ability

    def initialize
      can %i[read update], Order
      can :read, Trade
      can %i[read update], Member

      can :manage, Deposit
      can :manage, Withdraw

      can :manage, Operations::Account
      can :manage, Operations::Asset
      can :manage, Operations::Expense
      can :manage, Operations::Liability
      can :manage, Operations::Revenue

      can :manage, Engine
      can :manage, Market
      can :manage, Currency
      can :manage, Blockchain
      can :manage, Beneficiary
      can :manage, Wallet
      can :manage, TradingFee
      can :manage, Adjustment

      can :read, Account
      can :read, PaymentAddress
    end
  end
end
