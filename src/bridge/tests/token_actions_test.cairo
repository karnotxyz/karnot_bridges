use piltover::messaging::interface::IMessagingDispatcherTrait;
use starknet_bridge::bridge::token_bridge::TokenBridge::__member_module_appchain_bridge::InternalContractMemberStateTrait;
use starknet_bridge::bridge::token_bridge::TokenBridge::TokenBridgeInternal;
use starknet_bridge::bridge::token_bridge::TokenBridge::__member_module_token_settings::InternalContractMemberStateTrait as tokenSettingsStateTrait;
use snforge_std as snf;
use snforge_std::ContractClassTrait;
use starknet::{ContractAddress, storage::StorageMemberAccessTrait};
use starknet_bridge::mocks::{
    messaging::{IMockMessagingDispatcherTrait, IMockMessagingDispatcher}, erc20::ERC20
};
use piltover::messaging::interface::IMessagingDispatcher;
use starknet_bridge::bridge::{
    ITokenBridge, ITokenBridgeAdmin, ITokenBridgeDispatcher, ITokenBridgeDispatcherTrait,
    ITokenBridgeAdminDispatcher, ITokenBridgeAdminDispatcherTrait, IWithdrawalLimitStatusDispatcher,
    IWithdrawalLimitStatusDispatcherTrait, TokenBridge, TokenBridge::Event,
    types::{TokenStatus, TokenSettings}
};
use openzeppelin::access::ownable::{
    OwnableComponent, OwnableComponent::Event as OwnableEvent,
    interface::{IOwnableTwoStepDispatcher, IOwnableTwoStepDispatcherTrait}
};
use starknet_bridge::bridge::tests::utils::message_payloads;
use starknet_bridge::mocks::hash;
use starknet::contract_address::{contract_address_const};
use starknet_bridge::constants;

use starknet_bridge::bridge::tests::constants::{
    OWNER, L3_BRIDGE_ADDRESS, USDC_MOCK_ADDRESS, DELAY_TIME
};


/// Returns the state of a contract for testing. This must be used
/// to test internal functions or directly access the storage.
/// You can't spy event with this. Use deploy instead.
pub fn mock_state_testing() -> TokenBridge::ContractState {
    TokenBridge::contract_state_for_testing()
}

fn deploy_erc20(name: ByteArray, symbol: ByteArray) -> ContractAddress {
    let erc20_class_hash = snf::declare("ERC20").unwrap();
    let mut constructor_args = ArrayTrait::new();
    name.serialize(ref constructor_args);
    symbol.serialize(ref constructor_args);
    let fixed_supply: u256 = 1000000000;
    fixed_supply.serialize(ref constructor_args);
    OWNER().serialize(ref constructor_args);

    let (usdc, _) = erc20_class_hash.deploy(@constructor_args).unwrap();
    return usdc;
}

#[test]
fn deactivate_token_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Active, ..old_settings });

    mock.deactivate_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Deactivated, 'Token not deactivated');
}

#[test]
#[should_panic(expected: ('Token not active',))]
fn deactivate_token_not_active() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.deactivate_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Deactivated, 'Token not deactivated');
}


#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn deactivate_token_not_owner() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(snf::test_address());

    mock.deactivate_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Deactivated, 'Token not deactivated');
}

#[test]
fn block_token_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.block_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Blocked, 'Token not blocked');
}


#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn block_token_not_owner() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(snf::test_address());

    mock.block_token(usdc_address);
}

#[test]
#[should_panic(expected: ('Only unknown can be blocked',))]
fn block_token_not_unknown() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Active, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.block_token(usdc_address);
}

#[test]
fn unblock_token_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Blocked, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.unblock_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Unknown, 'Not unblocked');
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn unblock_token_not_owner() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Blocked, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(snf::test_address());

    mock.unblock_token(usdc_address);
}


#[test]
#[should_panic(expected: ('Token not blocked',))]
fn unblock_token_not_blocked() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Active, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.unblock_token(usdc_address);
}

#[test]
fn reactivate_token_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(
            usdc_address, TokenSettings { token_status: TokenStatus::Deactivated, ..old_settings }
        );

    mock.ownable.Ownable_owner.write(OWNER());

    snf::start_cheat_caller_address_global(OWNER());

    mock.reactivate_token(usdc_address);
    assert(mock.get_status(usdc_address) == TokenStatus::Active, 'Did not reactivate');
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn reactivate_token_not_owner() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(
            usdc_address, TokenSettings { token_status: TokenStatus::Deactivated, ..old_settings }
        );

    snf::start_cheat_caller_address_global(snf::test_address());

    mock.reactivate_token(usdc_address);
}

#[test]
#[should_panic(expected: ('Token not deactivated',))]
fn reactivate_token_not_deactivated() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Blocked, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());
    snf::start_cheat_caller_address_global(OWNER());

    mock.reactivate_token(usdc_address);
}

#[test]
#[should_panic(expected: ('Incorrect token status',))]
fn enroll_token_blocked() {
    let mut mock = mock_state_testing();

    let usdc_address = USDC_MOCK_ADDRESS();

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Blocked, ..old_settings });

    mock.ownable.Ownable_owner.write(OWNER());

    snf::start_cheat_caller_address_global(OWNER());
    mock.enroll_token(usdc_address);
}


#[test]
fn get_status_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    assert(mock.get_status(usdc_address) == TokenStatus::Unknown, 'Incorrect status');

    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Active, ..old_settings });

    assert(mock.get_status(usdc_address) == TokenStatus::Active, 'Incorrect status');

    // Setting the token
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Blocked, ..old_settings });

    assert(mock.get_status(usdc_address) == TokenStatus::Blocked, 'Incorrect status');
}


#[test]
fn is_servicing_token_ok() {
    let mut mock = mock_state_testing();
    let usdc_address = USDC_MOCK_ADDRESS();

    assert(mock.is_servicing_token(usdc_address) == false, 'Should not be servicing');
    // Setting the token active
    let old_settings = mock.token_settings.read(usdc_address);
    mock
        .token_settings
        .write(usdc_address, TokenSettings { token_status: TokenStatus::Active, ..old_settings });

    assert(mock.is_servicing_token(usdc_address) == true, 'Should be servicing');
}

