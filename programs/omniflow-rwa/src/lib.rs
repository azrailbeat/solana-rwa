use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Mint};
use mpl_token_metadata::instruction as mpl_instruction;
use mpl_token_metadata::state::{Metadata, TokenMetadataAccount};
use solana_program::program::invoke;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

pub mod errors;
pub mod identity;
pub use errors::*;
pub use identity::*;

#[program]
pub mod omniflow_rwa {
    use super::*;

    /// Initialize the RWA registry
    pub fn initialize_registry(
        ctx: Context<InitializeRegistry>,
        authority: Pubkey,
        wormhole_bridge: Option<Pubkey>,
        layerzero_endpoint: Option<Pubkey>,
    ) -> Result<()> {
        let registry = &mut ctx.accounts.registry;
        registry.authority = authority;
        registry.total_assets = 0;
        registry.wormhole_bridge = wormhole_bridge;
        registry.layerzero_endpoint = layerzero_endpoint;
        registry.paused = false;
        registry.bump = ctx.bumps.registry;

        emit!(RegistryInitialized {
            authority,
            wormhole_bridge,
            layerzero_endpoint,
        });

        Ok(())
    }

    /// Register a new RWA asset
    pub fn register_rwa_asset(
        ctx: Context<RegisterRWAAsset>,
        asset_id: u64,
        asset_type: AssetType,
        metadata_uri: String,
        kyc_level: KYCLevel,
        total_value: u64,
        total_supply: u64,
        chain_id: u16, // Target chain for cross-chain operations
    ) -> Result<()> {
        require!(!ctx.accounts.registry.paused, ErrorCode::RegistryPaused);
        require!(metadata_uri.len() <= 200, ErrorCode::MetadataUriTooLong);

        let asset = &mut ctx.accounts.asset;
        let registry = &mut ctx.accounts.registry;

        asset.asset_id = asset_id;
        asset.asset_type = asset_type;
        asset.owner = ctx.accounts.owner.key();
        asset.metadata_uri = metadata_uri.clone();
        asset.kyc_level = kyc_level;
        asset.total_value = total_value;
        asset.total_supply = total_supply;
        asset.circulating_supply = 0;
        asset.is_active = true;
        asset.created_at = Clock::get()?.unix_timestamp;
        asset.chain_id = chain_id;
        asset.bump = ctx.bumps.asset;

        registry.total_assets = registry.total_assets.checked_add(1).unwrap();

        // Emit cross-chain event for Wormhole/LayerZero
        emit!(RWAAssetRegistered {
            asset_id,
            owner: ctx.accounts.owner.key(),
            asset_type,
            metadata_uri,
            kyc_level,
            total_value,
            total_supply,
            chain_id,
            timestamp: Clock::get()?.unix_timestamp,
        });

        // Emit cross-chain bridge event if bridge is configured
        if let Some(wormhole_bridge) = registry.wormhole_bridge {
            emit!(CrossChainEvent {
                event_type: CrossChainEventType::AssetRegistered,
                asset_id,
                source_chain: 1, // Solana chain ID
                target_chain: chain_id,
                bridge_address: wormhole_bridge,
                data: asset_id.to_le_bytes().to_vec(),
            });
        }

        Ok(())
    }

    /// Mint RWA tokens (fractional ownership)
    pub fn mint_rwa_tokens(
        ctx: Context<MintRWATokens>,
        asset_id: u64,
        amount: u64,
    ) -> Result<()> {
        let asset = &mut ctx.accounts.asset;
        require!(asset.is_active, ErrorCode::AssetInactive);
        require!(amount > 0, ErrorCode::InvalidAmount);

        // Prevent minting more than 10% of total supply in single transaction
        let max_mint_per_tx = asset.total_supply / 10;
        require!(
            amount <= max_mint_per_tx,
            ErrorCode::ExceedsSingleMintLimit
        );

        require!(
            asset.circulating_supply.checked_add(amount).unwrap() <= asset.total_supply,
            ErrorCode::ExceedsMaxSupply
        );

        // Update circulating supply
        asset.circulating_supply = asset.circulating_supply.checked_add(amount).unwrap();

        // Mint tokens to user
        let cpi_accounts = token::MintTo {
            mint: ctx.accounts.mint.to_account_info(),
            to: ctx.accounts.token_account.to_account_info(),
            authority: ctx.accounts.asset.to_account_info(),
        };

        let asset_seeds = &[
            b"asset",
            &asset.asset_id.to_le_bytes(),
            &[asset.bump],
        ];
        let signer_seeds = &[&asset_seeds[..]];

        let cpi_program = ctx.accounts.token_program.to_account_info();
        let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, signer_seeds);

        token::mint_to(cpi_ctx, amount)?;

        emit!(RWATokensMinted {
            asset_id,
            recipient: ctx.accounts.recipient.key(),
            amount,
            timestamp: Clock::get()?.unix_timestamp,
        });

        Ok(())
    }

    /// Initiate cross-chain transfer
    pub fn initiate_cross_chain_transfer(
        ctx: Context<InitiateCrossChainTransfer>,
        asset_id: u64,
        amount: u64,
        target_chain: u16,
        target_recipient: [u8; 32],
    ) -> Result<()> {
        let asset = &ctx.accounts.asset;
        require!(asset.is_active, ErrorCode::AssetInactive);

        // Burn tokens on Solana
        let cpi_accounts = token::Burn {
            mint: ctx.accounts.mint.to_account_info(),
            from: ctx.accounts.from_token_account.to_account_info(),
            authority: ctx.accounts.owner.to_account_info(),
        };

        let cpi_program = ctx.accounts.token_program.to_account_info();
        let cpi_ctx = CpiContext::new(cpi_program, cpi_accounts);

        token::burn(cpi_ctx, amount)?;

        // Create cross-chain message
        let transfer_data = CrossChainTransferData {
            asset_id,
            amount,
            recipient: target_recipient,
            source_chain: 1, // Solana
            kyc_level: asset.kyc_level,
            metadata_uri: asset.metadata_uri.clone(),
        };

        emit!(CrossChainTransferInitiated {
            asset_id,
            amount,
            source_chain: 1,
            target_chain,
            sender: ctx.accounts.owner.key(),
            recipient: target_recipient,
            timestamp: Clock::get()?.unix_timestamp,
        });

        // Emit bridge-specific event
        emit!(CrossChainEvent {
            event_type: CrossChainEventType::TransferInitiated,
            asset_id,
            source_chain: 1,
            target_chain,
            bridge_address: ctx.accounts.registry.wormhole_bridge.unwrap_or_default(),
            data: borsh::to_vec(&transfer_data)?,
        });

        Ok(())
    }

    /// Complete cross-chain transfer (receive from other chain)
    pub fn complete_cross_chain_transfer(
        ctx: Context<CompleteCrossChainTransfer>,
        asset_id: u64,
        amount: u64,
        source_chain: u16,
        transfer_hash: [u8; 32],
    ) -> Result<()> {
        let asset = &mut ctx.accounts.asset;
        require!(asset.is_active, ErrorCode::AssetInactive);

        // Mint tokens on Solana
        let cpi_accounts = token::MintTo {
            mint: ctx.accounts.mint.to_account_info(),
            to: ctx.accounts.to_token_account.to_account_info(),
            authority: ctx.accounts.asset.to_account_info(),
        };

        let asset_seeds = &[
            b"asset",
            &asset.asset_id.to_le_bytes(),
            &[asset.bump],
        ];
        let signer_seeds = &[&asset_seeds[..]];

        let cpi_program = ctx.accounts.token_program.to_account_info();
        let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, signer_seeds);

        token::mint_to(cpi_ctx, amount)?;

        // Update circulating supply
        asset.circulating_supply = asset.circulating_supply.checked_add(amount).unwrap();

        emit!(CrossChainTransferCompleted {
            asset_id,
            amount,
            source_chain,
            target_chain: 1, // Solana
            recipient: ctx.accounts.recipient.key(),
            transfer_hash,
            timestamp: Clock::get()?.unix_timestamp,
        });

        Ok(())
    }

    /// Update asset metadata (owner only)
    pub fn update_asset_metadata(
        ctx: Context<UpdateAssetMetadata>,
        asset_id: u64,
        new_metadata_uri: String,
        new_kyc_level: Option<KYCLevel>,
    ) -> Result<()> {
        require!(new_metadata_uri.len() <= 200, ErrorCode::MetadataUriTooLong);

        let asset = &mut ctx.accounts.asset;
        asset.metadata_uri = new_metadata_uri.clone();
        
        if let Some(kyc_level) = new_kyc_level {
            asset.kyc_level = kyc_level;
        }

        emit!(AssetMetadataUpdated {
            asset_id,
            new_metadata_uri,
            new_kyc_level,
            timestamp: Clock::get()?.unix_timestamp,
        });

        Ok(())
    }

    /// Pause/unpause registry (authority only)
    pub fn set_registry_pause(
        ctx: Context<SetRegistryPause>,
        paused: bool,
    ) -> Result<()> {
        ctx.accounts.registry.paused = paused;

        emit!(RegistryPauseChanged {
            paused,
            timestamp: Clock::get()?.unix_timestamp,
        });

        Ok(())
    }
}

// Account Structs
#[derive(Accounts)]
pub struct InitializeRegistry<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + Registry::INIT_SPACE,
        seeds = [b"registry"],
        bump
    )]
    pub registry: Account<'info, Registry>,
    
    #[account(mut)]
    pub payer: Signer<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(asset_id: u64)]
pub struct RegisterRWAAsset<'info> {
    #[account(
        init,
        payer = owner,
        space = 8 + RWAAsset::INIT_SPACE,
        seeds = [b"asset", &asset_id.to_le_bytes()],
        bump
    )]
    pub asset: Account<'info, RWAAsset>,
    
    #[account(
        mut,
        seeds = [b"registry"],
        bump = registry.bump
    )]
    pub registry: Account<'info, Registry>,
    
    #[account(mut)]
    pub owner: Signer<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(asset_id: u64)]
pub struct MintRWATokens<'info> {
    #[account(
        mut,
        seeds = [b"asset", &asset_id.to_le_bytes()],
        bump = asset.bump,
        has_one = owner
    )]
    pub asset: Account<'info, RWAAsset>,
    
    #[account(mut)]
    pub mint: Account<'info, Mint>,
    
    #[account(
        init_if_needed,
        payer = owner,
        associated_token::mint = mint,
        associated_token::authority = recipient
    )]
    pub token_account: Account<'info, TokenAccount>,
    
    /// CHECK: Recipient can be any account
    pub recipient: AccountInfo<'info>,
    
    #[account(mut)]
    pub owner: Signer<'info>,
    
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(asset_id: u64)]
pub struct InitiateCrossChainTransfer<'info> {
    #[account(
        seeds = [b"asset", &asset_id.to_le_bytes()],
        bump = asset.bump
    )]
    pub asset: Account<'info, RWAAsset>,
    
    #[account(
        seeds = [b"registry"],
        bump = registry.bump
    )]
    pub registry: Account<'info, Registry>,
    
    #[account(mut)]
    pub mint: Account<'info, Mint>,
    
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = owner
    )]
    pub from_token_account: Account<'info, TokenAccount>,
    
    #[account(mut)]
    pub owner: Signer<'info>,
    
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(asset_id: u64)]
pub struct CompleteCrossChainTransfer<'info> {
    #[account(
        mut,
        seeds = [b"asset", &asset_id.to_le_bytes()],
        bump = asset.bump
    )]
    pub asset: Account<'info, RWAAsset>,
    
    #[account(mut)]
    pub mint: Account<'info, Mint>,
    
    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = mint,
        associated_token::authority = recipient
    )]
    pub to_token_account: Account<'info, TokenAccount>,
    
    /// CHECK: Recipient can be any account
    pub recipient: AccountInfo<'info>,
    
    #[account(mut)]
    pub payer: Signer<'info>,
    
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(asset_id: u64)]
pub struct UpdateAssetMetadata<'info> {
    #[account(
        mut,
        seeds = [b"asset", &asset_id.to_le_bytes()],
        bump = asset.bump,
        has_one = owner
    )]
    pub asset: Account<'info, RWAAsset>,
    
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct SetRegistryPause<'info> {
    #[account(
        mut,
        seeds = [b"registry"],
        bump = registry.bump,
        has_one = authority
    )]
    pub registry: Account<'info, Registry>,
    
    pub authority: Signer<'info>,
}

// Data Structs
#[account]
#[derive(InitSpace)]
pub struct Registry {
    pub authority: Pubkey,
    pub total_assets: u64,
    pub wormhole_bridge: Option<Pubkey>,
    pub layerzero_endpoint: Option<Pubkey>,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct RWAAsset {
    pub asset_id: u64,
    pub asset_type: AssetType,
    pub owner: Pubkey,
    #[max_len(200)]
    pub metadata_uri: String,
    pub kyc_level: KYCLevel,
    pub total_value: u64,
    pub total_supply: u64,
    pub circulating_supply: u64,
    pub is_active: bool,
    pub created_at: i64,
    pub chain_id: u16,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum AssetType {
    RealEstate,
    CarbonCredits,
    PreciousMetals,
    Commodities,
    Artwork,
    Collectibles,
    Other,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum KYCLevel {
    None,
    Basic,
    Enhanced,
    Institutional,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum CrossChainEventType {
    AssetRegistered,
    TransferInitiated,
    TransferCompleted,
    MetadataUpdated,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct CrossChainTransferData {
    pub asset_id: u64,
    pub amount: u64,
    pub recipient: [u8; 32],
    pub source_chain: u16,
    pub kyc_level: KYCLevel,
    #[max_len(200)]
    pub metadata_uri: String,
}

// Events
#[event]
pub struct RegistryInitialized {
    pub authority: Pubkey,
    pub wormhole_bridge: Option<Pubkey>,
    pub layerzero_endpoint: Option<Pubkey>,
}

#[event]
pub struct RWAAssetRegistered {
    pub asset_id: u64,
    pub owner: Pubkey,
    pub asset_type: AssetType,
    #[index]
    pub metadata_uri: String,
    pub kyc_level: KYCLevel,
    pub total_value: u64,
    pub total_supply: u64,
    pub chain_id: u16,
    pub timestamp: i64,
}

#[event]
pub struct RWATokensMinted {
    pub asset_id: u64,
    pub recipient: Pubkey,
    pub amount: u64,
    pub timestamp: i64,
}

#[event]
pub struct CrossChainTransferInitiated {
    pub asset_id: u64,
    pub amount: u64,
    pub source_chain: u16,
    pub target_chain: u16,
    pub sender: Pubkey,
    pub recipient: [u8; 32],
    pub timestamp: i64,
}

#[event]
pub struct CrossChainTransferCompleted {
    pub asset_id: u64,
    pub amount: u64,
    pub source_chain: u16,
    pub target_chain: u16,
    pub recipient: Pubkey,
    pub transfer_hash: [u8; 32],
    pub timestamp: i64,
}

#[event]
pub struct CrossChainEvent {
    pub event_type: CrossChainEventType,
    pub asset_id: u64,
    pub source_chain: u16,
    pub target_chain: u16,
    pub bridge_address: Pubkey,
    pub data: Vec<u8>,
}

#[event]
pub struct AssetMetadataUpdated {
    pub asset_id: u64,
    pub new_metadata_uri: String,
    pub new_kyc_level: Option<KYCLevel>,
    pub timestamp: i64,
}

#[event]
pub struct RegistryPauseChanged {
    pub paused: bool,
    pub timestamp: i64,
}

// Error Codes
#[error_code]
pub enum ErrorCode {
    #[msg("Registry is currently paused")]
    RegistryPaused,
    #[msg("Metadata URI is too long (max 200 characters)")]
    MetadataUriTooLong,
    #[msg("Asset is not active")]
    AssetInactive,
    #[msg("Amount exceeds maximum supply")]
    ExceedsMaxSupply,
    #[msg("Insufficient balance")]
    InsufficientBalance,
    #[msg("Invalid cross-chain operation")]
    InvalidCrossChainOperation,
    #[msg("Unauthorized access")]
    Unauthorized,
    #[msg("Amount must be greater than zero")]
    InvalidAmount,
    #[msg("Amount exceeds single mint limit (max 10% of total supply)")]
    ExceedsSingleMintLimit,
}
