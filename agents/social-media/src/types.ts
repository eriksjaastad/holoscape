export interface SkinConcept {
  id: string;
  name: string;
  createdAt: string;
  mood: string; // The input prompt
  windowShape: string; // e.g., "Organic blob with flowing edges"
  colorPalette: {
    primary: string; // Hex code
    secondary: string;
    accent: string;
    background: string;
  };
  particleBehavior: string; // e.g., "Slow orbital drift with occasional pulses"
  typography: string; // e.g., "Clean sans-serif, slightly condensed"
  personality: string; // AI persona prompt
  vibe: string; // One-liner, e.g., "Westworld meets vaporwave"
}

export interface GenerateOptions {
  mood?: string;
  save?: boolean;
  post?: boolean;
}

export type Platform = 'instagram' | 'twitter' | 'facebook';

export interface Caption {
  platform: Platform;
  text: string;
  hashtags: string[];
  characterCount: number;
}

export interface CaptionSet {
  instagram: Caption;
  twitter: Caption;
  facebook: Caption;
}

export type PostStatus = 'pending' | 'approved' | 'rejected' | 'posted';

export interface PostPackage {
  id: string;
  createdAt: string;
  concept: SkinConcept;
  imagePath: string;
  captions: CaptionSet;
  altText: string;
  suggestedTime: string;
  reasoning: string;
  platforms: Platform[];
  status: PostStatus;
  approvedAt?: string;
  rejectedAt?: string;
  rejectedReason?: string;
  postedAt?: string;
}

export interface Decision {
  id: string;
  packageId: string;
  action: 'created' | 'approved' | 'rejected' | 'regenerated' | 'posted';
  timestamp: string;
  reason?: string;
  metadata?: Record<string, unknown>;
}
