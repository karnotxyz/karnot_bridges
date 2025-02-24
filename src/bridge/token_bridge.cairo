#[starknet::contract]
pub mod TokenBridge {
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapWriteAccess,
        StorageMapReadAccess,
    };
    use starknet::SyscallResultTrait;
    use starknet_bridge::withdrawal_limit::component::WithdrawalLimitComponent::InternalTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use core::panic_with_felt252;
    use core::starknet::event::EventEmitter;
    use starknet::storage::Map;
    use core::array::ArrayTrait;
    use core::serde::Serde;
    use core::num::traits::Bounded;
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20MetadataDispatcher, IERC20DispatcherTrait,
        IERC20MetadataDispatcherTrait,
    };
    use starknet::syscalls::call_contract_syscall;
    use core::to_byte_array::FormatAsByteArray;

    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::security::reentrancyguard::{
        ReentrancyGuardComponent,
        ReentrancyGuardComponent::InternalTrait as InternalReentrancyGuardImpl,
    };

    use piltover::messaging::types::MessageToAppchainStatus;


    use starknet_bridge::withdrawal_limit::component::WithdrawalLimitComponent;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: WithdrawalLimitComponent, storage: withdrawal, event: WithdrawalEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    use core::num::traits::zero::Zero;
    use starknet::{ContractAddress, get_contract_address, get_caller_address, get_block_timestamp};

    use starknet_bridge::bridge::{
        types::{TokenStatus, TokenSettings},
        interface::{ITokenBridge, ITokenBridgeAdmin, IWithdrawalLimitStatus},
    };
    use piltover::messaging::{
        interface::{IMessagingDispatcher, IMessagingDispatcherTrait}, types::{MessageHash, Nonce},
    };
    use starknet_bridge::constants;
    use starknet::ClassHash;


    // Ownable
    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // WithdrawalLimit
    #[abi(embed_v0)]
    impl WithdrawalLimitImpl =
        WithdrawalLimitComponent::WithdrawalLimitImpl<ContractState>;
    impl WithdrawalLimitInternal = WithdrawalLimitComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        // corresponding bridge contract_address deployed on the appchain
        appchain_bridge: ContractAddress,
        // the core messaging contract deployed on starknet used for l2 - l3 messsaging
        messaging_contract: IMessagingDispatcher,
        // All token related settings and its status
        token_settings: Map<ContractAddress, TokenSettings>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        withdrawal: WithdrawalLimitComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    //
    // Errors
    //
    pub mod Errors {
        pub const APPCHAIN_BRIDGE_NOT_SET: felt252 = 'L3 bridge not set';
        pub const ZERO_DEPOSIT: felt252 = 'Zero amount';
        pub const ALREADY_ENROLLED: felt252 = 'Incorrect token status';
        pub const DEPLOYMENT_MESSAGE_DOES_NOT_EXIST: felt252 = 'Deployment message inexistent';
        pub const DEPLOYMENT_MESSAGE_CANCELLED: felt252 = 'Deployment message cancelled';
        pub const DEPLOYMENT_MESSAGE_SEALED: felt252 = 'Deployment message sealed';
        pub const NOT_ACTIVE: felt252 = 'Token not active';
        pub const NOT_DEACTIVATED: felt252 = 'Token not deactivated';
        pub const NOT_BLOCKED: felt252 = 'Token not blocked';
        pub const NOT_UNKNOWN: felt252 = 'Only unknown can be blocked';
        pub const NOT_SERVICING: felt252 = 'Only servicing tokens';
        pub const INVALID_RECIPIENT: felt252 = 'Invalid recipient';
        pub const MAX_BALANCE_EXCEEDED: felt252 = 'Max Balance Exceeded';
        pub const TOKENS_NOT_TRANSFERRED: felt252 = 'Tokens not transferred';
    }


    #[derive(Drop, starknet::Event)]
    #[event]
    pub enum Event {
        TokenEnrollmentInitiated: TokenEnrollmentInitiated,
        TokenActivated: TokenActivated,
        TokenDeactivated: TokenDeactivated,
        TokenBlocked: TokenBlocked,
        TokenReactivated: TokenReactivated,
        TokenUnblocked: TokenUnblocked,
        Deposit: Deposit,
        DepositWithMessage: DepositWithMessage,
        DepostiCancelRequest: DepositCancelRequest,
        DepositWithMessageCancelRequest: DepositWithMessageCancelRequest,
        DepositReclaimed: DepositReclaimed,
        DepositWithMessageReclaimed: DepositWithMessageReclaimed,
        Withdrawal: Withdrawal,
        WithdrawalLimitEnabled: WithdrawalLimitEnabled,
        WithdrawalLimitDisabled: WithdrawalLimitDisabled,
        SetMaxTotalBalance: SetMaxTotalBalance,
        SetAppchainBridge: SetAppchainBridge,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        WithdrawalEvent: WithdrawalLimitComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenActivated {
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenDeactivated {
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenBlocked {
        pub token: ContractAddress,
    }


    #[derive(Drop, starknet::Event)]
    pub struct TokenUnblocked {
        pub token: ContractAddress,
    }


    #[derive(Drop, starknet::Event)]
    pub struct TokenReactivated {
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenEnrollmentInitiated {
        pub token: ContractAddress,
        pub deployment_message_hash: MessageHash,
    }


    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositWithMessage {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub message: Span<felt252>,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositCancelRequest {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositWithMessageCancelRequest {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub message: Span<felt252>,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositReclaimed {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositWithMessageReclaimed {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        #[key]
        pub appchain_recipient: ContractAddress,
        pub message: Span<felt252>,
        pub nonce: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdrawal {
        #[key]
        pub recipient: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WithdrawalLimitEnabled {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WithdrawalLimitDisabled {
        #[key]
        pub sender: ContractAddress,
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetMaxTotalBalance {
        #[key]
        pub token: ContractAddress,
        pub value: u256,
    }


    #[derive(Drop, starknet::Event)]
    pub struct SetAppchainBridge {
        pub appchain_bridge: ContractAddress,
    }


    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        appchain_bridge: ContractAddress,
        messaging_contract: ContractAddress,
        owner: ContractAddress,
    ) {
        self.appchain_bridge.write(appchain_bridge);
        self
            .messaging_contract
            .write(IMessagingDispatcher { contract_address: messaging_contract });
        self.withdrawal.initialize(5);
        self.ownable.initializer(owner);
    }


    #[generate_trait]
    pub impl TokenBridgeInternalImpl of TokenBridgeInternal {
        fn send_deploy_message(self: @ContractState, token: ContractAddress) -> felt252 {
            assert(self.appchain_bridge().is_non_zero(), Errors::APPCHAIN_BRIDGE_NOT_SET);

            let (hash, _nonce) = self
                .messaging_contract
                .read()
                .send_message_to_appchain(
                    self.appchain_bridge(),
                    constants::HANDLE_TOKEN_DEPLOYMENT_SELECTOR,
                    deployment_message_payload(token),
                );
            return hash;
        }

        fn send_deposit_message(
            self: @ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            message: Span<felt252>,
            selector: felt252,
        ) -> Nonce {
            assert(self.appchain_bridge().is_non_zero(), Errors::APPCHAIN_BRIDGE_NOT_SET);
            assert(amount > 0, Errors::ZERO_DEPOSIT);

            let is_with_message = selector == constants::HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR;
            let (_, nonce) = self
                .messaging_contract
                .read()
                .send_message_to_appchain(
                    self.appchain_bridge(),
                    selector,
                    deposit_message_payload(
                        token, amount, appchain_recipient, is_with_message, message,
                    ),
                );
            nonce
        }

        fn consume_message(
            self: @ContractState, token: ContractAddress, amount: u256, recipient: ContractAddress,
        ) {
            assert(recipient.is_non_zero(), Errors::INVALID_RECIPIENT);

            let appchain_bridge = self.appchain_bridge();
            assert(appchain_bridge.is_non_zero(), Errors::APPCHAIN_BRIDGE_NOT_SET);
            let mut payload = ArrayTrait::new();
            constants::TRANSFER_FROM_APPCHAIN.serialize(ref payload);
            recipient.serialize(ref payload);
            token.serialize(ref payload);
            amount.serialize(ref payload);
            self
                .messaging_contract
                .read()
                .consume_message_from_appchain(appchain_bridge, payload.span());
        }

        fn accept_deposit(self: @ContractState, token: ContractAddress, amount: u256) {
            assert(self.is_servicing_token(token), Errors::NOT_SERVICING);
            let caller = get_caller_address();
            let dispatcher = IERC20Dispatcher { contract_address: token };

            let current_balance: u256 = dispatcher.balance_of(get_contract_address());
            let max_total_balance = self.get_max_total_balance(token);
            assert(current_balance + amount < max_total_balance, Errors::MAX_BALANCE_EXCEEDED);

            let this_address = get_contract_address();
            let initial_balance = dispatcher.balance_of(this_address);
            dispatcher.transfer_from(caller, this_address, amount);
            assert(
                dispatcher.balance_of(this_address) == initial_balance + amount,
                Errors::TOKENS_NOT_TRANSFERRED,
            );
        }
    }


    pub fn deposit_message_payload(
        token: ContractAddress,
        amount: u256,
        appchain_recipient: ContractAddress,
        is_with_message: bool,
        message: Span<felt252>,
    ) -> Span<felt252> {
        let caller = get_caller_address();
        let mut payload = ArrayTrait::new();
        token.serialize(ref payload);
        caller.serialize(ref payload);
        appchain_recipient.serialize(ref payload);
        amount.serialize(ref payload);
        if (is_with_message) {
            message.serialize(ref payload);
        }

        return payload.span();
    }

    fn deserialize_and_append(
        mut value: Span<felt252>, mut calldata: Array<felt252>,
    ) -> Array<felt252> {
        if (value.len() == 1) {
            let value_byte_array = value[0].format_as_byte_array(10);
            value_byte_array.serialize(ref calldata);
        } else {
            let value_byte_array = Serde::<ByteArray>::deserialize(ref value).unwrap();
            value_byte_array.serialize(ref calldata);
        }
        calldata
    }

    pub fn deployment_message_payload(token: ContractAddress) -> Span<felt252> {
        // Create the calldata that will be sent to on_receive. l2_token, amount and
        // depositor are the fields from the deposit context.
        let mut calldata = ArrayTrait::new();
        let dispatcher = IERC20MetadataDispatcher { contract_address: token };
        token.serialize(ref calldata);

        // Openzeppelin erc20 used felt252 as return types for `name()` and `symbol()` before while
        // `ByteArray` is used currently.
        // So we use underlying syscalls, to support both the interface.
        // The returned span is deserialized into to a ByteArray in both cases to make it consistent
        // In case of ByteArray the length of returned span will be at least 3, while exactly 1 for
        // felt252
        let name_selector = selector!("name");
        let mut name = call_contract_syscall(token, name_selector, array![].span())
            .unwrap_syscall();
        calldata = deserialize_and_append(name, calldata);

        let symbol_selector = selector!("symbol");
        let mut symbol = call_contract_syscall(token, symbol_selector, array![].span())
            .unwrap_syscall();
        calldata = deserialize_and_append(symbol, calldata);

        // dispatcher.name().serialize(ref calldata);
        // dispatcher.symbol().serialize(ref calldata);

        dispatcher.decimals().serialize(ref calldata);
        calldata.span()
    }


    #[abi(embed_v0)]
    impl TokenBrdigeAdminImpl of ITokenBridgeAdmin<ContractState> {
        fn set_appchain_token_bridge(ref self: ContractState, appchain_bridge: ContractAddress) {
            self.ownable.assert_only_owner();
            self.appchain_bridge.read();

            self.emit(SetAppchainBridge { appchain_bridge });
        }

        // @dev Only Unknown tokens can be blocked, for stopping deposits on an
        // `Active` token check `deactivate_token()`
        // @param token The address of the token contract to be blocked
        // No return value, but it updates the token's status to 'Blocked'.
        // Emits a `TokenBlocked` event when the blocking is successful.
        // Throws an error if the token is not `Unknown` or if the sender is not the owner.
        fn block_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(self.get_status(token) == TokenStatus::Unknown, Errors::NOT_UNKNOWN);

            let new_settings = TokenSettings {
                token_status: TokenStatus::Blocked, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);
            self.emit(TokenBlocked { token });
        }

        // @dev This unblocks a token which can be enrolled now
        // @param token The address of the token to unblock
        fn unblock_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(self.get_status(token) == TokenStatus::Blocked, Errors::NOT_BLOCKED);

            let new_settings = TokenSettings {
                token_status: TokenStatus::Unknown, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);
            self.emit(TokenUnblocked { token });
        }

        // @dev Only `Active` tokens can be deactivated. For `Unknown` tokens
        // check `block_token()`
        // @param token The token to be deactivated
        fn deactivate_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            let status = self.get_status(token);
            assert(status == TokenStatus::Active, Errors::NOT_ACTIVE);

            let new_settings = TokenSettings {
                token_status: TokenStatus::Deactivated, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);

            self.emit(TokenDeactivated { token });
        }

        // @dev This is reactivates back a token to `Active` that was deactivated
        // @param token The address of the token to be reactivated
        fn reactivate_token(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            let status = self.get_status(token);
            assert(status == TokenStatus::Deactivated, Errors::NOT_DEACTIVATED);

            let new_settings = TokenSettings {
                token_status: TokenStatus::Active, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);

            self.emit(TokenReactivated { token });
        }


        // @dev This can be used to enable daily withdrawal limits on a token,
        // @param token The address of the token on which to enable withdrawal limit
        fn enable_withdrawal_limit(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            let new_settings = TokenSettings {
                withdrawal_limit_applied: true, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);
            self.emit(WithdrawalLimitEnabled { sender: get_caller_address(), token });
        }

        fn disable_withdrawal_limit(ref self: ContractState, token: ContractAddress) {
            self.ownable.assert_only_owner();
            let new_settings = TokenSettings {
                withdrawal_limit_applied: false, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);
            self.emit(WithdrawalLimitDisabled { sender: get_caller_address(), token });
        }

        // Use this to add a max total balance on the token. Beyond this value no more deposits
        // will be accepted. In case of L3 this would mean the maximum supply of token that
        // can be taken from L2 to L3
        fn set_max_total_balance(
            ref self: ContractState, token: ContractAddress, max_total_balance: u256,
        ) {
            self.ownable.assert_only_owner();
            let new_settings = TokenSettings {
                max_total_balance: max_total_balance, ..self.token_settings.read(token),
            };
            self.token_settings.write(token, new_settings);
            self.emit(SetMaxTotalBalance { token, value: max_total_balance });
        }
    }

    #[abi(embed_v0)]
    impl TokenBridgeImpl of ITokenBridge<ContractState> {
        fn appchain_bridge(self: @ContractState) -> ContractAddress {
            return self.appchain_bridge.read();
        }

        fn get_identity(self: @ContractState) -> felt252 {
            constants::CONTRACT_IDENTITY
        }

        fn get_version(self: @ContractState) -> felt252 {
            constants::CONTRACT_VERSION
        }


        //    Initiates the enrollment of a token into the system.
        //    This function is used to initiate the enrollment process of a token.
        //    The token is marked as 'Pending' because the success of the deployment is uncertain at
        //    this stage.
        //    The deployment message's existence is checked, indicating that deployment has been
        //    attempted.
        //    The success of the deployment is determined at a later stage during the application's
        //    lifecycle.
        //    The function is permissionless and can be called by anyone
        //
        //    @param token The address of the token contract to be enrolled.
        //    No return value, but it updates the token's status to 'Pending' and records the
        //    deployment message and expiration time.
        //    Emits a `TokenEnrollmentInitiated` event when the enrollment is initiated.
        //    Throws an error if the sender is not the manager or if the deployment message does not
        //    exist.

        fn enroll_token(ref self: ContractState, token: ContractAddress) {
            assert(self.get_status(token) == TokenStatus::Unknown, Errors::ALREADY_ENROLLED);

            // Send message to appchain
            let deployment_message_hash = self.send_deploy_message(token);

            let message_status = self
                .messaging_contract
                .read()
                .sn_to_appchain_messages(deployment_message_hash);

            match message_status {
                MessageToAppchainStatus::Pending => {},
                MessageToAppchainStatus::Cancelled => {
                    panic_with_felt252(Errors::DEPLOYMENT_MESSAGE_CANCELLED)
                },
                MessageToAppchainStatus::Sealed => {
                    panic_with_felt252(Errors::DEPLOYMENT_MESSAGE_SEALED)
                },
                MessageToAppchainStatus::NotSent => {
                    panic_with_felt252(Errors::DEPLOYMENT_MESSAGE_DOES_NOT_EXIST)
                },
            };

            // Reading existing settings as withdrawal_limit_applied and max_total_balance
            // can be set before the token is enrolled.
            let old_settings = self.token_settings.read(token);
            let new_settings = TokenSettings {
                token_status: TokenStatus::Pending,
                deployment_message_hash: deployment_message_hash,
                pending_deployment_expiration: get_block_timestamp()
                    + constants::MAX_PENDING_DURATION.try_into().unwrap(),
                ..old_settings,
            };

            self.token_settings.write(token, new_settings);
            self.emit(TokenEnrollmentInitiated { token, deployment_message_hash });
        }

        // @dev Used to create a deposit of for the token,
        // which sends a l2-l3 message to mint the user `amount` tokens
        // @param token: Address of the token to deposit
        // @param amount: quantity of tokens
        // @param appchain_recipient: address of the recipient on l3
        fn deposit(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
        ) {
            self.reentrancy_guard.start();
            let no_message: Span<felt252> = array![].span();
            self.accept_deposit(token, amount);
            let nonce = self
                .send_deposit_message(
                    token,
                    amount,
                    appchain_recipient,
                    no_message.clone(),
                    constants::HANDLE_TOKEN_DEPOSIT_SELECTOR,
                );

            let caller = get_caller_address();
            self.emit(Deposit { sender: caller, token, amount, appchain_recipient, nonce });

            self.check_deployment_status(token);
            self.reentrancy_guard.end();
        }

        // @dev This is function is used if one intends to make a contract call
        // post the deposit on l3. The calldata can be passed in `message` parameter
        // `deposit()` funciton is maintained to diverge as less as possible from Starkgate(L1-L2
        // bridges)
        fn deposit_with_message(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            message: Span<felt252>,
        ) {
            self.accept_deposit(token, amount);
            let nonce = self
                .send_deposit_message(
                    token,
                    amount,
                    appchain_recipient,
                    message,
                    constants::HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
                );

            let caller = get_caller_address();
            self
                .emit(
                    DepositWithMessage {
                        sender: caller, token, amount, appchain_recipient, message, nonce,
                    },
                );
            // Piggy-back the deposit tx to check and update the status of token bridge deployment.
            self.check_deployment_status(token);
            self.reentrancy_guard.end();
        }

        //     checks token deployment status.
        //     relies on l3 clearing l2-l3 message upon successful completion of deployment.
        //     processing: check the l2-l3 deployment message. set status to `Active` if consumed.
        //     if not consumed after the expected duration, it returns the status to `Unknown`.
        fn check_deployment_status(ref self: ContractState, token: ContractAddress) {
            let settings = self.token_settings.read(token);
            if (settings.token_status != TokenStatus::Pending) {
                return;
            }

            let message_status = self
                .messaging_contract
                .read()
                .sn_to_appchain_messages(settings.deployment_message_hash);

            if (message_status == MessageToAppchainStatus::Sealed) {
                let new_settings = TokenSettings { token_status: TokenStatus::Active, ..settings };
                self.token_settings.write(token, new_settings);
                self.emit(TokenActivated { token });
            } else if (get_block_timestamp() > settings.pending_deployment_expiration) {
                let new_settings = TokenSettings { token_status: TokenStatus::Unknown, ..settings };
                self.token_settings.write(token, new_settings);
            }
        }


        // For withdrawing
        // 1. the user burns the tokens on l3, which registers
        // a message on the messaging contract (piltover).
        //
        // 2. Calls `withdraw()` which consumes the message in the piltover
        // and transfers the tokens to the `recipient`
        fn withdraw(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
        ) {
            self.reentrancy_guard.start();

            self.consume_message(token, amount, recipient);

            assert(recipient.is_non_zero(), Errors::INVALID_RECIPIENT);
            self.withdrawal.consume_withdrawal_quota(token, amount);

            let tokenDispatcher = IERC20Dispatcher { contract_address: token };
            tokenDispatcher.transfer(recipient, amount);
            self.reentrancy_guard.end();

            self.emit(Withdrawal { recipient, token, amount });
        }

        // /*
        //   A deposit cancellation requires two steps:
        //   1. The depositor should send a `deposit_cancel_request()` request with deposit details
        //   & nonce.
        //   2. After a predetermined time (cancellation delay), the depositor can claim back the
        //   funds by
        //      calling `deposit_reclaim` (using the same arguments).
        //
        //   Note: As long as the `deposit_reclaim` was not performed, the deposit may be processed,
        //   even if
        //         the cancellation delay time has already passed. Only the depositor is allowed to
        //         cancel a deposit, and only before `deposit_reclaim` was performed.
        // */
        fn deposit_cancel_request(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            nonce: Nonce,
        ) {
            let no_message: Span<felt252> = array![].span();
            self
                .messaging_contract
                .read()
                .start_message_cancellation(
                    self.appchain_bridge(),
                    constants::HANDLE_TOKEN_DEPOSIT_SELECTOR,
                    deposit_message_payload(token, amount, appchain_recipient, false, no_message),
                    nonce,
                );
            self
                .emit(
                    DepositCancelRequest {
                        sender: get_caller_address(), token, amount, appchain_recipient, nonce,
                    },
                );
        }

        // @dev If the deposit was initiated by `deposit_with_message()` then use this.
        // If not check `deposit_cancel_request()`
        fn deposit_with_message_cancel_request(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            message: Span<felt252>,
            nonce: Nonce,
        ) {
            self
                .messaging_contract
                .read()
                .start_message_cancellation(
                    self.appchain_bridge(),
                    constants::HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
                    deposit_message_payload(token, amount, appchain_recipient, true, message),
                    nonce,
                );
            self
                .emit(
                    DepositWithMessageCancelRequest {
                        sender: get_caller_address(),
                        token,
                        amount,
                        appchain_recipient,
                        message,
                        nonce,
                    },
                );
        }

        // Similar to `deposit_reclaim()` with the difference of deposit initiated with
        // `deposit_with_message()`
        fn deposit_with_message_reclaim(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            message: Span<felt252>,
            nonce: Nonce,
        ) {
            self.reentrancy_guard.start();
            self
                .messaging_contract
                .read()
                .cancel_message(
                    self.appchain_bridge(),
                    constants::HANDLE_DEPOSIT_WITH_MESSAGE_SELECTOR,
                    deposit_message_payload(token, amount, appchain_recipient, true, message),
                    nonce,
                );

            let dispatcher = IERC20Dispatcher { contract_address: token };
            dispatcher.transfer(get_caller_address(), amount);

            self.reentrancy_guard.end();

            self
                .emit(
                    DepositWithMessageReclaimed {
                        sender: get_caller_address(),
                        token,
                        amount,
                        appchain_recipient,
                        message,
                        nonce,
                    },
                );
        }

        // After the `cancellation delay time` has passed of the generating the cancellation request
        // a valid message can be cancelled.
        fn deposit_reclaim(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            appchain_recipient: ContractAddress,
            nonce: Nonce,
        ) {
            self.reentrancy_guard.start();
            let no_message: Span<felt252> = array![].span();
            self
                .messaging_contract
                .read()
                .cancel_message(
                    self.appchain_bridge(),
                    constants::HANDLE_TOKEN_DEPOSIT_SELECTOR,
                    deposit_message_payload(token, amount, appchain_recipient, false, no_message),
                    nonce,
                );

            let dispatcher = IERC20Dispatcher { contract_address: token };
            dispatcher.transfer(get_caller_address(), amount);

            self.reentrancy_guard.end();

            self
                .emit(
                    DepositReclaimed {
                        sender: get_caller_address(), token, amount, appchain_recipient, nonce,
                    },
                );
        }


        fn get_status(self: @ContractState, token: ContractAddress) -> TokenStatus {
            self.token_settings.read(token).token_status
        }

        fn is_servicing_token(self: @ContractState, token: ContractAddress) -> bool {
            self.token_settings.read(token).token_status == TokenStatus::Active
        }

        fn get_max_total_balance(self: @ContractState, token: ContractAddress) -> u256 {
            let max_total_balance = self.token_settings.read(token).max_total_balance;
            if (max_total_balance == 0) {
                return Bounded::MAX;
            }
            return max_total_balance;
        }
    }


    #[abi(embed_v0)]
    impl WithdrawalLimitStatusImpl of IWithdrawalLimitStatus<ContractState> {
        fn is_withdrawal_limit_applied(self: @ContractState, token: ContractAddress) -> bool {
            self.token_settings.read(token).withdrawal_limit_applied
        }
    }


    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            // This function can only be called by the owner
            self.ownable.assert_only_owner();

            // Replace the class hash upgrading the contract
            self.upgradeable.upgrade(new_class_hash);
        }
    }
}

