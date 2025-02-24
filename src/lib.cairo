pub mod bridge {
    pub mod token_bridge;
    pub mod interface;
    pub mod types;

    #[cfg(test)]
    pub mod tests {
        pub mod constants;
        mod token_actions_test;
        mod messaging_test;
        pub mod utils {
            pub mod message_payloads;
            pub mod setup;
        }
    }

    pub use token_bridge::TokenBridge;
    pub use interface::{
        ITokenBridge, ITokenBridgeAdmin, IWithdrawalLimitStatus, ITokenBridgeDispatcher,
        ITokenBridgeAdminDispatcher, IWithdrawalLimitStatusDispatcher,
        IWithdrawalLimitStatusDispatcherTrait, ITokenBridgeDispatcherTrait,
        ITokenBridgeAdminDispatcherTrait,
    };
}

pub mod withdrawal_limit {
    pub mod component;
    pub mod interface;

    #[cfg(test)]
    mod tests {
        mod withdrawal_limit_test;
    }
}

pub mod constants;

pub mod mocks {
    pub mod erc20;

    #[cfg(test)]
    pub mod messaging;

    #[cfg(test)]
    pub mod messaging_malicious;

    #[cfg(test)]
    pub mod withdrawal_limit_mock;

    #[cfg(test)]
    pub mod hash;
}

