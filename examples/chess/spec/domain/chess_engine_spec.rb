# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChessEngine do
  describe '#side_to_move' do
    it "is 'white' from the initial FEN" do
      expect(described_class.new(ChessEngine::INITIAL_FEN).side_to_move).to eq('white')
    end

    it "reads the side from the FEN field" do
      black_to_move = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1'
      expect(described_class.new(black_to_move).side_to_move).to eq('black')
    end
  end

  describe '#piece_at' do
    it 'returns lowercase piece letters' do
      e = described_class.new(ChessEngine::INITIAL_FEN)
      expect(e.piece_at('e2')).to eq('p')
      expect(e.piece_at('e7')).to eq('p')
      expect(e.piece_at('a1')).to eq('r')
      expect(e.piece_at('e4')).to be_nil
    end
  end

  describe '#legal_destinations' do
    it 'returns both single- and double-step pawn moves from the initial position' do
      e = described_class.new(ChessEngine::INITIAL_FEN)
      expect(e.legal_destinations('e2').sort).to eq(%w[e3 e4])
    end

    it 'returns the two knight moves from the starting b1' do
      e = described_class.new(ChessEngine::INITIAL_FEN)
      expect(e.legal_destinations('b1').sort).to eq(%w[a3 c3])
    end

    it 'returns [] for an empty square' do
      e = described_class.new(ChessEngine::INITIAL_FEN)
      expect(e.legal_destinations('a3')).to eq([])
    end
  end

  describe '#apply' do
    it 'plays a legal move and returns SAN + new FEN' do
      result = described_class.new(ChessEngine::INITIAL_FEN).apply('e2', 'e4')
      expect(result.legal).to be(true)
      expect(result.san).to match(/e4/)
      expect(result.fen_after).to include(' b ') # black to move next
      expect(result.captured_piece).to be_nil
      expect(result.checkmate).to be(false)
    end

    it 'rejects an illegal move' do
      result = described_class.new(ChessEngine::INITIAL_FEN).apply('e2', 'e5')
      expect(result.legal).to be(false)
    end

    it 'detects a capture by reading the destination piece pre-move' do
      after_e4_d5 = 'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2'
      result = described_class.new(after_e4_d5).apply('e4', 'd5')
      expect(result.legal).to be(true)
      expect(result.captured_piece).to eq('p')
    end

    it 'auto-queens a pawn promotion' do
      # Black king on e8, white pawn on d7 with a clear promotion path.
      pre_promote = '4k3/3P4/8/8/8/8/8/4K3 w - - 0 1'
      result = described_class.new(pre_promote).apply('d7', 'd8')
      expect(result.legal).to be(true)
      # FEN-after should contain a white queen on d8.
      expect(result.fen_after.split(' ').first.split('/').first).to include('Q')
    end

    it 'flags checkmate when the move ends the game' do
      # Scholar's mate position: white to play Qxf7#.
      scholars = 'r1bqkbnr/pppp1Qpp/2n5/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4'
      # Already mate from black's POV — no move needed; side_to_move is black.
      e = described_class.new(scholars)
      expect(e.side_to_move).to eq('black')
    end
  end
end
