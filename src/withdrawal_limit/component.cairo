#[starknet::component]
pub mod WithdrawalLimitComponent {
    use starknet::{ContractAddress, get_block_timestamp, get_contract_address};
    use starknet_bridge::{constants, bridge::IWithdrawalLimitStatus};
    use core::num::traits::Bounded;
    use starknet::storage::Map;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapWriteAccess,
        StorageMapReadAccess,
    };

    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet_bridge::withdrawal_limit::interface::IWithdrawalLimit;

    #[storage]
    pub struct Storage {
        // For each token and day, stores the amount that can still be withdrawn from this token
        // in this day (if the value is x, the amount left to withdraw is x-1). 0 means that
        // currently there was no withdrawal from this token in this day or there were withdrawals
        // but the limit flag was turned off.
        remaining_intraday_withdraw_quota: Map<(ContractAddress, u64), u256>,
        // The daily withdrawal limit percentage.
        daily_withdrawal_limit_pct: u8,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        RemainingQuotaUpdated: RemainingQuotaUpdated,
        DailyWithdrawalPercentageUpdated: DailyWithdrawalPercentageUpdated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RemainingQuotaUpdated {
        pub token: ContractAddress,
        pub day: u64,
        pub new_quota: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DailyWithdrawalPercentageUpdated {
        pub new_percentage: u8,
    }

    #[embeddable_as(WithdrawalLimitImpl)]
    pub impl WithdrawalLimit<
        TContractState, +HasComponent<TContractState>, +IWithdrawalLimitStatus<TContractState>,
    > of IWithdrawalLimit<ComponentState<TContractState>> {
        // Returns the current remaining withdrawal quota for a given token. If there is no limit,
        // returns max uint256. If the limit was not set yet, we calculate it based on the total
        // supply. Otherwise, return the limit.
        fn get_remaining_withdrawal_quota(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> u256 {
            // If there is no limt, return max uint256.
            if self.get_contract().is_withdrawal_limit_applied(:token) == false {
                return Bounded::MAX;
            }
            let remaining_quota = self.read_withdrawal_quota_slot(:token);

            // if remaining_quota is 0 then quota is not initialised
            if remaining_quota == 0 {
                return self.get_daily_withdrawal_limit(:token);
            }
            remaining_quota - constants::REMAINING_QUOTA_OFFSET
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +IWithdrawalLimitStatus<TContractState>,
    > of InternalTrait<TContractState> {
        // This initializes the withdrawal_limit component
        fn initialize(ref self: ComponentState<TContractState>, daily_withdrawal_limit_pct: u8) {
            self.daily_withdrawal_limit_pct.write(daily_withdrawal_limit_pct);
        }

        // Sets the remaining withdrawal quota for today.
        fn set_remaining_withdrawal_quota(
            ref self: ComponentState<TContractState>, token: ContractAddress, amount: u256,
        ) {
            let now = get_block_timestamp();
            let day = now / constants::SECONDS_IN_DAY;
            self
                .remaining_intraday_withdraw_quota
                .write((token, day), amount + constants::REMAINING_QUOTA_OFFSET);

            self.emit(RemainingQuotaUpdated { token: token, day: day, new_quota: amount });
        }

        // Returns the remaining withdrawal quota for today.
        fn read_withdrawal_quota_slot(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> u256 {
            let now = get_block_timestamp();
            let day = now / constants::SECONDS_IN_DAY;
            self.remaining_intraday_withdraw_quota.read((token, day))
        }


        // Try to withdraw an amount and if it succeeds, update the remaining withdrawal quota.
        fn consume_withdrawal_quota(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            amount_to_withdraw: u256,
        ) {
            if (!self.get_contract().is_withdrawal_limit_applied(:token)) {
                return;
            }
            let remaining_withdrawal_quota = self.get_remaining_withdrawal_quota(token);

            assert(remaining_withdrawal_quota >= amount_to_withdraw, 'LIMIT_EXCEEDED');
            self
                .set_remaining_withdrawal_quota(
                    :token, amount: remaining_withdrawal_quota - amount_to_withdraw,
                )
        }

        // Returns the full quota of the daily withdrawal limit for a given token.
        // The calculation is based on the limit percentage and current token total supply.
        // Note - while techincally, we're exposed to overflow error here, we consider that
        // risk non-existant for any token of even the smallest value.
        fn get_daily_withdrawal_limit(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> u256 {
            let dispatcher = IERC20Dispatcher { contract_address: token };
            let balance = dispatcher.balance_of(get_contract_address());
            let daily_withdrawal_limit_pct: u256 = self.get_daily_withdrawal_limit_pct().into();
            balance * daily_withdrawal_limit_pct / 100
        }

        fn get_daily_withdrawal_limit_pct(self: @ComponentState<TContractState>) -> u8 {
            self.daily_withdrawal_limit_pct.read()
        }


        fn write_daily_withdrawal_limit_pct(
            ref self: ComponentState<TContractState>, daily_withdrawal_limit_pct: u8,
        ) {
            assert(daily_withdrawal_limit_pct <= 100, 'LIMIT_PCT_TOO_HIGH');
            self.daily_withdrawal_limit_pct.write(daily_withdrawal_limit_pct);

            self
                .emit(
                    DailyWithdrawalPercentageUpdated { new_percentage: daily_withdrawal_limit_pct },
                );
        }
    }
}
