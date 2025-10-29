import { EventEmitter } from 'events';
import { ChainProvider } from '../core/types';
import { 
  Asset, 
  MarketplaceListing, 
  Transaction, 
  ChainId,
  SDKError,
  ListingType,
  ListingStatus,
  MarketplaceFilter
} from '../core/types';

/**
 * Marketplace Manager - Handles RWA marketplace operations across chains
 */
export class MarketplaceManager extends EventEmitter {
  private providers: Map<ChainId, ChainProvider>;
  private listings: Map<string, MarketplaceListing> = new Map();

  constructor(providers: Map<ChainId, ChainProvider>) {
    super();
    this.providers = providers;
  }

  /**
   * Create a new marketplace listing
   */
  async createListing(
    asset: Asset,
    price: string,
    listingType: ListingType,
    duration?: number
  ): Promise<MarketplaceListing> {
    const provider = this.providers.get(asset.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${asset.chainId}`, 'CHAIN_ERROR');
    }

    try {
      const listingId = `${asset.chainId}-listing-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
      const expiresAt = duration ? new Date(Date.now() + duration * 1000) : undefined;

      const listing: MarketplaceListing = {
        id: listingId,
        assetId: asset.id,
        chainId: asset.chainId,
        seller: asset.owner,
        price,
        currency: asset.currency,
        listingType,
        status: 'active',
        createdAt: new Date(),
        updatedAt: new Date(),
        expiresAt,
        bids: [],
        views: 0,
        favorites: 0,
      };

      // If OneChain provider, use specialized listing method
      if (asset.chainId === 'onechain' && 'listAssetOnMarketplace' in provider) {
        const tx = await (provider as any).listAssetOnMarketplace(
          asset.tokenId,
          price,
          listingType
        );
        
        listing.transactionHash = tx.hash;
        this.emit('listingCreated', { listing, transaction: tx });
      } else {
        // Generic marketplace contract interaction
        this.emit('listingCreated', { listing });
      }

      this.listings.set(listingId, listing);
      return listing;
    } catch (error) {
      throw new SDKError(`Failed to create listing: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Get listing by ID
   */
  async getListing(listingId: string): Promise<MarketplaceListing | null> {
    return this.listings.get(listingId) || null;
  }

  /**
   * Get all listings with optional filtering
   */
  async getListings(filter?: MarketplaceFilter): Promise<MarketplaceListing[]> {
    let listings = Array.from(this.listings.values());

    if (filter) {
      if (filter.chainId) {
        listings = listings.filter(listing => listing.chainId === filter.chainId);
      }
      if (filter.seller) {
        listings = listings.filter(listing => listing.seller.toLowerCase() === filter.seller!.toLowerCase());
      }
      if (filter.listingType) {
        listings = listings.filter(listing => listing.listingType === filter.listingType);
      }
      if (filter.status) {
        listings = listings.filter(listing => listing.status === filter.status);
      }
      if (filter.minPrice) {
        listings = listings.filter(listing => parseFloat(listing.price) >= filter.minPrice!);
      }
      if (filter.maxPrice) {
        listings = listings.filter(listing => parseFloat(listing.price) <= filter.maxPrice!);
      }
      if (filter.assetType) {
        // This would require asset lookup - simplified for demo
        listings = listings.filter(listing => listing.assetId.includes(filter.assetType!));
      }
    }

    return listings.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  /**
   * Purchase an asset from marketplace
   */
  async purchaseAsset(listingId: string, buyerAddress: string): Promise<Transaction> {
    const listing = this.listings.get(listingId);
    if (!listing) {
      throw new SDKError(`Listing not found: ${listingId}`, 'LISTING_ERROR');
    }

    if (listing.status !== 'active') {
      throw new SDKError(`Listing is not active: ${listing.status}`, 'LISTING_ERROR');
    }

    if (listing.listingType !== 'fixed') {
      throw new SDKError('Only fixed price listings can be purchased directly', 'LISTING_ERROR');
    }

    const provider = this.providers.get(listing.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${listing.chainId}`, 'CHAIN_ERROR');
    }

    try {
      // Create purchase transaction
      const tx = await provider.sendTransaction({
        to: listing.contractAddress || '',
        value: listing.price,
        data: this.encodePurchaseData(listing.id, buyerAddress),
      });

      // Update listing status
      listing.status = 'sold';
      listing.buyer = buyerAddress;
      listing.updatedAt = new Date();
      this.listings.set(listingId, listing);

      this.emit('assetPurchased', { listing, buyer: buyerAddress, transaction: tx });
      return tx;
    } catch (error) {
      throw new SDKError(`Failed to purchase asset: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Place bid on auction listing
   */
  async placeBid(listingId: string, bidderAddress: string, bidAmount: string): Promise<Transaction> {
    const listing = this.listings.get(listingId);
    if (!listing) {
      throw new SDKError(`Listing not found: ${listingId}`, 'LISTING_ERROR');
    }

    if (listing.status !== 'active') {
      throw new SDKError(`Listing is not active: ${listing.status}`, 'LISTING_ERROR');
    }

    if (listing.listingType !== 'auction') {
      throw new SDKError('Bids can only be placed on auction listings', 'LISTING_ERROR');
    }

    const provider = this.providers.get(listing.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${listing.chainId}`, 'CHAIN_ERROR');
    }

    // Validate bid amount
    const currentHighestBid = listing.bids.length > 0 
      ? Math.max(...listing.bids.map(bid => parseFloat(bid.amount)))
      : parseFloat(listing.price);

    if (parseFloat(bidAmount) <= currentHighestBid) {
      throw new SDKError('Bid must be higher than current highest bid', 'BID_ERROR');
    }

    try {
      // Create bid transaction
      const tx = await provider.sendTransaction({
        to: listing.contractAddress || '',
        value: bidAmount,
        data: this.encodeBidData(listing.id, bidderAddress, bidAmount),
      });

      // Add bid to listing
      const bid = {
        bidder: bidderAddress,
        amount: bidAmount,
        timestamp: new Date(),
        transactionHash: tx.hash,
      };

      listing.bids.push(bid);
      listing.updatedAt = new Date();
      this.listings.set(listingId, listing);

      this.emit('bidPlaced', { listing, bid, transaction: tx });
      return tx;
    } catch (error) {
      throw new SDKError(`Failed to place bid: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Cancel a listing
   */
  async cancelListing(listingId: string, sellerAddress: string): Promise<Transaction> {
    const listing = this.listings.get(listingId);
    if (!listing) {
      throw new SDKError(`Listing not found: ${listingId}`, 'LISTING_ERROR');
    }

    if (listing.seller.toLowerCase() !== sellerAddress.toLowerCase()) {
      throw new SDKError('Only the seller can cancel the listing', 'AUTHORIZATION_ERROR');
    }

    if (listing.status !== 'active') {
      throw new SDKError(`Cannot cancel listing with status: ${listing.status}`, 'LISTING_ERROR');
    }

    const provider = this.providers.get(listing.chainId);
    if (!provider) {
      throw new SDKError(`Provider not found for chain: ${listing.chainId}`, 'CHAIN_ERROR');
    }

    try {
      // Create cancellation transaction
      const tx = await provider.sendTransaction({
        to: listing.contractAddress || '',
        data: this.encodeCancelData(listing.id),
      });

      // Update listing status
      listing.status = 'cancelled';
      listing.updatedAt = new Date();
      this.listings.set(listingId, listing);

      this.emit('listingCancelled', { listing, transaction: tx });
      return tx;
    } catch (error) {
      throw new SDKError(`Failed to cancel listing: ${error}`, 'TRANSACTION_ERROR');
    }
  }

  /**
   * Update listing price
   */
  async updateListingPrice(listingId: string, newPrice: string, sellerAddress: string): Promise<MarketplaceListing> {
    const listing = this.listings.get(listingId);
    if (!listing) {
      throw new SDKError(`Listing not found: ${listingId}`, 'LISTING_ERROR');
    }

    if (listing.seller.toLowerCase() !== sellerAddress.toLowerCase()) {
      throw new SDKError('Only the seller can update the listing price', 'AUTHORIZATION_ERROR');
    }

    if (listing.status !== 'active') {
      throw new SDKError(`Cannot update price for listing with status: ${listing.status}`, 'LISTING_ERROR');
    }

    listing.price = newPrice;
    listing.updatedAt = new Date();
    this.listings.set(listingId, listing);

    this.emit('listingUpdated', { listing });
    return listing;
  }

  /**
   * Get marketplace statistics
   */
  async getMarketplaceStats(): Promise<{
    totalListings: number;
    activeListings: number;
    totalVolume: string;
    averagePrice: string;
    topAssetTypes: Array<{ type: string; count: number }>;
  }> {
    const listings = Array.from(this.listings.values());
    const activeListings = listings.filter(l => l.status === 'active');
    const soldListings = listings.filter(l => l.status === 'sold');

    const totalVolume = soldListings.reduce((sum, listing) => sum + parseFloat(listing.price), 0);
    const averagePrice = soldListings.length > 0 ? totalVolume / soldListings.length : 0;

    // Mock asset type counting
    const assetTypeCounts = new Map<string, number>();
    listings.forEach(listing => {
      const type = listing.assetId.split('-')[1] || 'unknown';
      assetTypeCounts.set(type, (assetTypeCounts.get(type) || 0) + 1);
    });

    const topAssetTypes = Array.from(assetTypeCounts.entries())
      .map(([type, count]) => ({ type, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);

    return {
      totalListings: listings.length,
      activeListings: activeListings.length,
      totalVolume: totalVolume.toString(),
      averagePrice: averagePrice.toString(),
      topAssetTypes,
    };
  }

  /**
   * Search listings
   */
  async searchListings(query: string): Promise<MarketplaceListing[]> {
    const listings = Array.from(this.listings.values());
    const lowerQuery = query.toLowerCase();

    return listings.filter(listing => 
      listing.assetId.toLowerCase().includes(lowerQuery) ||
      listing.seller.toLowerCase().includes(lowerQuery) ||
      listing.price.includes(lowerQuery)
    );
  }

  /**
   * Get trending listings
   */
  async getTrendingListings(limit: number = 10): Promise<MarketplaceListing[]> {
    const listings = Array.from(this.listings.values())
      .filter(l => l.status === 'active')
      .sort((a, b) => (b.views + b.favorites) - (a.views + a.favorites))
      .slice(0, limit);

    return listings;
  }

  /**
   * Get recent sales
   */
  async getRecentSales(limit: number = 10): Promise<MarketplaceListing[]> {
    const soldListings = Array.from(this.listings.values())
      .filter(l => l.status === 'sold')
      .sort((a, b) => b.updatedAt.getTime() - a.updatedAt.getTime())
      .slice(0, limit);

    return soldListings;
  }

  /**
   * Track listing view
   */
  async trackView(listingId: string): Promise<void> {
    const listing = this.listings.get(listingId);
    if (listing) {
      listing.views += 1;
      listing.updatedAt = new Date();
      this.listings.set(listingId, listing);
    }
  }

  /**
   * Toggle favorite listing
   */
  async toggleFavorite(listingId: string, userAddress: string): Promise<boolean> {
    const listing = this.listings.get(listingId);
    if (!listing) {
      throw new SDKError(`Listing not found: ${listingId}`, 'LISTING_ERROR');
    }

    // Simple favorite tracking (in production, this would be more sophisticated)
    listing.favorites += 1;
    listing.updatedAt = new Date();
    this.listings.set(listingId, listing);

    return true;
  }

  /**
   * Private helper methods
   */
  private encodePurchaseData(listingId: string, buyerAddress: string): string {
    // Mock purchase data encoding
    return `0x${listingId.slice(-16)}${buyerAddress.slice(2)}`;
  }

  private encodeBidData(listingId: string, bidderAddress: string, bidAmount: string): string {
    // Mock bid data encoding
    return `0x${listingId.slice(-16)}${bidderAddress.slice(2)}${parseInt(bidAmount).toString(16).padStart(16, '0')}`;
  }

  private encodeCancelData(listingId: string): string {
    // Mock cancel data encoding
    return `0x${listingId.slice(-16)}`;
  }

  /**
   * Load demo listings for demo presentations
   */
  async loadDemoListings(): Promise<MarketplaceListing[]> {
    const demoListings: Partial<MarketplaceListing>[] = [
      {
        assetId: 'onechain-real-estate-demo-1',
        chainId: 'onechain',
        seller: '0x1234567890123456789012345678901234567890',
        price: '2500000',
        currency: 'USD',
        listingType: 'fixed',
        status: 'active',
      },
      {
        assetId: 'onechain-renewable-energy-demo-2',
        chainId: 'onechain',
        seller: '0x2345678901234567890123456789012345678901',
        price: '5000000',
        currency: 'USD',
        listingType: 'auction',
        status: 'active',
        bids: [
          {
            bidder: '0x3456789012345678901234567890123456789012',
            amount: '4800000',
            timestamp: new Date(Date.now() - 3600000),
            transactionHash: '0xabc123...',
          },
        ],
      },
      {
        assetId: 'onechain-carbon-credits-demo-3',
        chainId: 'onechain',
        seller: '0x3456789012345678901234567890123456789012',
        price: '750000',
        currency: 'USD',
        listingType: 'fixed',
        status: 'active',
      },
    ];

    const createdListings: MarketplaceListing[] = [];
    for (const listingData of demoListings) {
      const listingId = `demo-listing-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
      
      const listing: MarketplaceListing = {
        id: listingId,
        assetId: listingData.assetId!,
        chainId: listingData.chainId!,
        seller: listingData.seller!,
        price: listingData.price!,
        currency: listingData.currency!,
        listingType: listingData.listingType!,
        status: listingData.status!,
        createdAt: new Date(),
        updatedAt: new Date(),
        bids: listingData.bids || [],
        views: Math.floor(Math.random() * 100),
        favorites: Math.floor(Math.random() * 20),
      };

      this.listings.set(listingId, listing);
      createdListings.push(listing);
    }

    return createdListings;
  }
}
