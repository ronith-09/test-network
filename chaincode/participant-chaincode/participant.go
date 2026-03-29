package main

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

const (
	walletKeyPrefix      = "wallet~"
	mintRequestKeyPrefix = "mintrequest~"
	settlementKeyPrefix  = "settlement~"
	betweenAdminMSPID    = "BetweenMSP"
)

// Participant represents an on-chain participant (bank)
type Participant struct {
	BankID                    string `json:"bankId"`
	BankDisplayName           string `json:"bankDisplayName"`
	BicSwiftCode              string `json:"bicSwiftCode"`
	CountryCode               string `json:"countryCode"`
	MspID                     string `json:"mspId"`
	Status                    string `json:"status"` // ACTIVE, SUSPENDED, REVOKED
	SupportedCurrencies       string `json:"supportedCurrencies"`
	SettlementModel           string `json:"settlementModel"`
	PublicKeyHash             string `json:"publicKeyHash"`
	CertificateThumbprintHash string `json:"certificateThumbprintHash"`
	JoinedDate                string `json:"joinedDate"`
	ClientID                  string `json:"clientId"`         // Certificate ID of activating admin
	CreatedBy                 string `json:"createdBy"`        // Admin user who activated
	LastModifiedBy            string `json:"lastModifiedBy"`   // Last admin who modified status
	LastModifiedDate          string `json:"lastModifiedDate"` // Last modification timestamp
}

type WalletBalance struct {
	Currency string `json:"currency"`
	Balance  int64  `json:"balance"`
}

type Wallet struct {
	WalletID  string          `json:"walletId"`
	BankID    string          `json:"bankId"`
	MspID     string          `json:"mspId"`
	Status    string          `json:"status"`
	Balances  []WalletBalance `json:"balances"`
	UpdatedAt string          `json:"updatedAt"`
}

type MintRequest struct {
	RequestID        string  `json:"requestId"`
	BankID           string  `json:"bankId"`
	Currency         string  `json:"currency"`
	Amount           int64   `json:"amount"`
	Reason           string  `json:"reason"`
	Status           string  `json:"status"`
	RequestedAt      string  `json:"requestedAt"`
	ReviewedAt       *string `json:"reviewedAt"`
	ReviewedBy       *string `json:"reviewedBy"`
	RejectionReason  *string `json:"rejectionReason"`
	ApprovalTxID     *string `json:"approvalTxId"`
	WalletSnapshotID *string `json:"walletSnapshotId"`
}

type Settlement struct {
	SettlementID    string  `json:"settlementId"`
	FromBank        string  `json:"fromBank"`
	ToBank          string  `json:"toBank"`
	Currency        string  `json:"currency"`
	Amount          int64   `json:"amount"`
	Reference       string  `json:"reference"`
	Purpose         string  `json:"purpose"`
	Status          string  `json:"status"`
	CreatedAt       string  `json:"createdAt"`
	ApprovedAt      *string `json:"approvedAt"`
	ApprovedBy      *string `json:"approvedBy"`
	RejectionReason *string `json:"rejectionReason"`
	CompletedAt     *string `json:"completedAt"`
	ExecutedBy      *string `json:"executedBy"`
	ExecutionTxID   *string `json:"executionTxId"`
}

type SettlementInvestigation struct {
	SettlementID  string              `json:"settlementId"`
	CurrentStatus string              `json:"currentStatus"`
	StoppedAtStep string              `json:"stoppedAtStep"`
	PendingWith   string              `json:"pendingWith"`
	Reason        string              `json:"reason"`
	ActionHistory []map[string]string `json:"actionHistory"`
	LastUpdatedAt string              `json:"lastUpdatedAt"`
}

// ParticipantChaincode implements the contract for participant management
type ParticipantChaincode struct {
	contractapi.Contract
}

// VerifyBetweenNetworkAdmin verifies that the caller is BetweenMSP
// This function is called by all governance/control functions
// ONLY BetweenMSP can invoke approve, suspend, revoke, reactivate operations
func (pc *ParticipantChaincode) VerifyBetweenNetworkAdmin(
	ctx contractapi.TransactionContextInterface,
	functionName string,
) (string, error) {
	// Get caller's MSP ID
	callerMSPID, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return "", fmt.Errorf("[AUTHORIZATION FAILED] %s: failed to get caller MSP ID: %v", functionName, err)
	}

	// Strict check: ONLY BetweenMSP is allowed
	if callerMSPID != betweenAdminMSPID {
		return "", fmt.Errorf("[UNAUTHORIZED ACCESS DENIED] %s: Caller MSP '%s' is not authorized. Only '%s' can invoke this function", functionName, callerMSPID, betweenAdminMSPID)
	}

	// Get caller's certificate ID for audit trail
	clientID, err := ctx.GetClientIdentity().GetID()
	if err != nil {
		return "", fmt.Errorf("[AUTHORIZATION FAILED] %s: failed to get caller certificate ID: %v", functionName, err)
	}

	return clientID, nil
}

// ActivateParticipant activates a new participant on-chain
// ONLY BetweenMSP can invoke this function
// Any other MSP will be rejected with authorization error
func (pc *ParticipantChaincode) ActivateParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	bankDisplayName string,
	bicSwiftCode string,
	countryCode string,
	mspID string,
	supportedCurrencies string,
	settlementModel string,
	publicKeyHash string,
	certificateThumbprintHash string,
	joinedDate string,
) error {
	// ========== AUTHORIZATION CHECK ==========
	// Verify only BetweenMSP can activate participants
	clientID, err := pc.VerifyBetweenNetworkAdmin(ctx, "ActivateParticipant")
	if err != nil {
		log.Printf("AUTHORIZATION DENIED - ActivateParticipant: %v", err)
		return err
	}

	// Check if participant already exists
	existing, err := pc.GetParticipant(ctx, bankID)
	if err == nil && existing != nil {
		return fmt.Errorf("participant with bankId %s already exists", bankID)
	}

	// Create new participant
	participant := Participant{
		BankID:                    bankID,
		BankDisplayName:           bankDisplayName,
		BicSwiftCode:              bicSwiftCode,
		CountryCode:               countryCode,
		MspID:                     mspID,
		Status:                    "ACTIVE",
		SupportedCurrencies:       supportedCurrencies,
		SettlementModel:           settlementModel,
		PublicKeyHash:             publicKeyHash,
		CertificateThumbprintHash: certificateThumbprintHash,
		JoinedDate:                joinedDate,
		ClientID:                  clientID,
		CreatedBy:                 clientID,
		LastModifiedBy:            clientID,
		LastModifiedDate:          joinedDate,
	}

	// Serialize and save to ledger
	participantJSON, err := json.Marshal(participant)
	if err != nil {
		return fmt.Errorf("failed to marshal participant: %v", err)
	}

	err = ctx.GetStub().PutState(bankID, participantJSON)
	if err != nil {
		return fmt.Errorf("failed to save participant to ledger: %v", err)
	}

	// Emit activation event
	err = ctx.GetStub().SetEvent("ParticipantActivated", participantJSON)
	if err != nil {
		return fmt.Errorf("failed to emit activation event: %v", err)
	}

	return nil
}

// GetParticipant retrieves a participant from the ledger
func (pc *ParticipantChaincode) GetParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) (*Participant, error) {
	participantJSON, err := ctx.GetStub().GetState(bankID)
	if err != nil {
		return nil, fmt.Errorf("failed to read from ledger: %v", err)
	}

	if participantJSON == nil {
		return nil, fmt.Errorf("participant %s does not exist", bankID)
	}

	var participant Participant
	err = json.Unmarshal(participantJSON, &participant)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal participant: %v", err)
	}

	return &participant, nil
}

func (pc *ParticipantChaincode) requireParticipantStatus(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	expectedStatus string,
) (*Participant, error) {
	participant, err := pc.GetParticipant(ctx, bankID)
	if err != nil {
		return nil, err
	}

	if participant.Status != expectedStatus {
		return nil, fmt.Errorf("participant %s status is %s; %s required", bankID, participant.Status, expectedStatus)
	}

	return participant, nil
}

func walletStateKey(bankID string) string {
	return walletKeyPrefix + bankID
}

func mintRequestStateKey(requestID string) string {
	return mintRequestKeyPrefix + requestID
}

func settlementStateKey(settlementID string) string {
	return settlementKeyPrefix + settlementID
}

func normalizeCurrency(currency string) string {
	return strings.ToUpper(strings.TrimSpace(currency))
}

func timestampToRFC3339(txTime *time.Time) string {
	if txTime == nil {
		return time.Now().UTC().Format(time.RFC3339)
	}

	return txTime.UTC().Format(time.RFC3339)
}

func stubTimestampAsTime(ctx contractapi.TransactionContextInterface) (*time.Time, error) {
	txTimestamp, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return nil, fmt.Errorf("failed to get tx timestamp: %v", err)
	}

	parsed := time.Unix(txTimestamp.Seconds, int64(txTimestamp.Nanos)).UTC()
	return &parsed, nil
}

func sortMintRequests(requests []*MintRequest) {
	sort.Slice(requests, func(i, j int) bool {
		return requests[i].RequestedAt > requests[j].RequestedAt
	})
}

func sortWalletBalances(balances []WalletBalance) {
	sort.Slice(balances, func(i, j int) bool {
		return balances[i].Currency < balances[j].Currency
	})
}

func sortSettlements(settlements []*Settlement) {
	sort.Slice(settlements, func(i, j int) bool {
		return settlements[i].CreatedAt > settlements[j].CreatedAt
	})
}

func (pc *ParticipantChaincode) getWallet(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) (*Wallet, error) {
	walletJSON, err := ctx.GetStub().GetState(walletStateKey(bankID))
	if err != nil {
		return nil, fmt.Errorf("failed to read wallet from ledger: %v", err)
	}

	if walletJSON == nil {
		participant, err := pc.requireParticipantStatus(ctx, bankID, "ACTIVE")
		if err != nil {
			return nil, err
		}

		return &Wallet{
			WalletID:  "wallet-" + bankID,
			BankID:    bankID,
			MspID:     participant.MspID,
			Status:    "ACTIVE",
			Balances:  []WalletBalance{},
			UpdatedAt: time.Now().UTC().Format(time.RFC3339),
		}, nil
	}

	var wallet Wallet
	if err := json.Unmarshal(walletJSON, &wallet); err != nil {
		return nil, fmt.Errorf("failed to unmarshal wallet: %v", err)
	}

	return &wallet, nil
}

func (pc *ParticipantChaincode) saveWallet(
	ctx contractapi.TransactionContextInterface,
	wallet *Wallet,
) error {
	sortWalletBalances(wallet.Balances)

	walletJSON, err := json.Marshal(wallet)
	if err != nil {
		return fmt.Errorf("failed to marshal wallet: %v", err)
	}

	if err := ctx.GetStub().PutState(walletStateKey(wallet.BankID), walletJSON); err != nil {
		return fmt.Errorf("failed to save wallet: %v", err)
	}

	return nil
}

func (pc *ParticipantChaincode) creditWallet(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	currency string,
	amount int64,
) (*Wallet, error) {
	if amount <= 0 {
		return nil, fmt.Errorf("amount must be greater than zero")
	}

	wallet, err := pc.getWallet(ctx, bankID)
	if err != nil {
		return nil, err
	}

	normalizedCurrency := normalizeCurrency(currency)
	if normalizedCurrency == "" {
		return nil, fmt.Errorf("currency is required")
	}

	found := false
	for i := range wallet.Balances {
		if wallet.Balances[i].Currency == normalizedCurrency {
			wallet.Balances[i].Balance += amount
			found = true
			break
		}
	}

	if !found {
		wallet.Balances = append(wallet.Balances, WalletBalance{
			Currency: normalizedCurrency,
			Balance:  amount,
		})
	}

	if now, err := stubTimestampAsTime(ctx); err == nil {
		wallet.UpdatedAt = timestampToRFC3339(now)
	}

	if err := pc.saveWallet(ctx, wallet); err != nil {
		return nil, err
	}

	return wallet, nil
}

func (pc *ParticipantChaincode) hasSufficientBalanceInWallet(
	wallet *Wallet,
	currency string,
	amount int64,
) bool {
	normalizedCurrency := normalizeCurrency(currency)
	for _, balance := range wallet.Balances {
		if balance.Currency == normalizedCurrency && balance.Balance >= amount {
			return true
		}
	}

	return false
}

func (pc *ParticipantChaincode) debitWallet(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	currency string,
	amount int64,
) (*Wallet, error) {
	if amount <= 0 {
		return nil, fmt.Errorf("amount must be greater than zero")
	}

	wallet, err := pc.getWallet(ctx, bankID)
	if err != nil {
		return nil, err
	}

	normalizedCurrency := normalizeCurrency(currency)
	if normalizedCurrency == "" {
		return nil, fmt.Errorf("currency is required")
	}

	found := false
	for i := range wallet.Balances {
		if wallet.Balances[i].Currency != normalizedCurrency {
			continue
		}

		if wallet.Balances[i].Balance < amount {
			return nil, fmt.Errorf("insufficient balance in %s wallet for currency %s", bankID, normalizedCurrency)
		}

		wallet.Balances[i].Balance -= amount
		found = true
		break
	}

	if !found {
		return nil, fmt.Errorf("wallet balance for currency %s not found", normalizedCurrency)
	}

	if now, err := stubTimestampAsTime(ctx); err == nil {
		wallet.UpdatedAt = timestampToRFC3339(now)
	}

	if err := pc.saveWallet(ctx, wallet); err != nil {
		return nil, err
	}

	return wallet, nil
}

func (pc *ParticipantChaincode) getMintRequest(
	ctx contractapi.TransactionContextInterface,
	requestID string,
) (*MintRequest, error) {
	requestJSON, err := ctx.GetStub().GetState(mintRequestStateKey(requestID))
	if err != nil {
		return nil, fmt.Errorf("failed to read mint request: %v", err)
	}

	if requestJSON == nil {
		return nil, fmt.Errorf("mint request %s does not exist", requestID)
	}

	var request MintRequest
	if err := json.Unmarshal(requestJSON, &request); err != nil {
		return nil, fmt.Errorf("failed to unmarshal mint request: %v", err)
	}

	return &request, nil
}

func (pc *ParticipantChaincode) saveMintRequest(
	ctx contractapi.TransactionContextInterface,
	request *MintRequest,
) error {
	requestJSON, err := json.Marshal(request)
	if err != nil {
		return fmt.Errorf("failed to marshal mint request: %v", err)
	}

	if err := ctx.GetStub().PutState(mintRequestStateKey(request.RequestID), requestJSON); err != nil {
		return fmt.Errorf("failed to save mint request: %v", err)
	}

	return nil
}

func (pc *ParticipantChaincode) listMintRequests(
	ctx contractapi.TransactionContextInterface,
	filter func(*MintRequest) bool,
) ([]*MintRequest, error) {
	iterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return nil, fmt.Errorf("failed to get state range: %v", err)
	}
	defer iterator.Close()

	var requests []*MintRequest
	for iterator.HasNext() {
		result, err := iterator.Next()
		if err != nil {
			return nil, err
		}

		if !strings.HasPrefix(result.Key, mintRequestKeyPrefix) {
			continue
		}

		var request MintRequest
		if err := json.Unmarshal(result.Value, &request); err != nil {
			return nil, fmt.Errorf("failed to unmarshal mint request: %v", err)
		}

		if filter == nil || filter(&request) {
			reqCopy := request
			requests = append(requests, &reqCopy)
		}
	}

	sortMintRequests(requests)
	return requests, nil
}

func (pc *ParticipantChaincode) getSettlement(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (*Settlement, error) {
	settlementJSON, err := ctx.GetStub().GetState(settlementStateKey(settlementID))
	if err != nil {
		return nil, fmt.Errorf("failed to read settlement: %v", err)
	}

	if settlementJSON == nil {
		return nil, fmt.Errorf("settlement %s does not exist", settlementID)
	}

	var settlement Settlement
	if err := json.Unmarshal(settlementJSON, &settlement); err != nil {
		return nil, fmt.Errorf("failed to unmarshal settlement: %v", err)
	}

	return &settlement, nil
}

func (pc *ParticipantChaincode) saveSettlement(
	ctx contractapi.TransactionContextInterface,
	settlement *Settlement,
) error {
	settlementJSON, err := json.Marshal(settlement)
	if err != nil {
		return fmt.Errorf("failed to marshal settlement: %v", err)
	}

	if err := ctx.GetStub().PutState(settlementStateKey(settlement.SettlementID), settlementJSON); err != nil {
		return fmt.Errorf("failed to save settlement: %v", err)
	}

	return nil
}

func (pc *ParticipantChaincode) listSettlements(
	ctx contractapi.TransactionContextInterface,
	filter func(*Settlement) bool,
) ([]*Settlement, error) {
	iterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return nil, fmt.Errorf("failed to get state range: %v", err)
	}
	defer iterator.Close()

	var settlements []*Settlement
	for iterator.HasNext() {
		result, err := iterator.Next()
		if err != nil {
			return nil, err
		}

		if !strings.HasPrefix(result.Key, settlementKeyPrefix) {
			continue
		}

		var settlement Settlement
		if err := json.Unmarshal(result.Value, &settlement); err != nil {
			return nil, fmt.Errorf("failed to unmarshal settlement: %v", err)
		}

		if filter == nil || filter(&settlement) {
			copySettlement := settlement
			settlements = append(settlements, &copySettlement)
		}
	}

	sortSettlements(settlements)
	return settlements, nil
}

// IsParticipantActive returns true only when the participant exists and is ACTIVE.
// Wallet and settlement flows should use this to decide whether the organization
// can be offered wallet functionality.
func (pc *ParticipantChaincode) IsParticipantActive(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) (bool, error) {
	participant, err := pc.GetParticipant(ctx, bankID)
	if err != nil {
		if err.Error() == fmt.Sprintf("participant %s does not exist", bankID) {
			return false, nil
		}

		return false, err
	}

	return participant.Status == "ACTIVE", nil
}

// RequireActiveParticipant enforces that a participant exists and is ACTIVE.
// Wallet creation, minting, and transfer chaincode can call this rule before
// allowing any wallet-related action for a bank.
func (pc *ParticipantChaincode) RequireActiveParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) error {
	_, err := pc.requireParticipantStatus(ctx, bankID, "ACTIVE")
	return err
}

// GetWallet returns the currency-based wallet for an active participant.
func (pc *ParticipantChaincode) GetWallet(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) (*Wallet, error) {
	_, err := pc.requireParticipantStatus(ctx, bankID, "ACTIVE")
	if err != nil {
		return nil, err
	}

	return pc.getWallet(ctx, bankID)
}

// CreateMintRequest stores a mint request for an active participant.
func (pc *ParticipantChaincode) CreateMintRequest(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	currency string,
	amount string,
	reason string,
) (*MintRequest, error) {
	_, err := pc.requireParticipantStatus(ctx, bankID, "ACTIVE")
	if err != nil {
		return nil, err
	}

	parsedAmount, err := strconv.ParseInt(amount, 10, 64)
	if err != nil || parsedAmount <= 0 {
		return nil, fmt.Errorf("amount must be a positive integer")
	}

	normalizedCurrency := normalizeCurrency(currency)
	if normalizedCurrency == "" {
		return nil, fmt.Errorf("currency is required")
	}

	requestedAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	request := &MintRequest{
		RequestID:   ctx.GetStub().GetTxID(),
		BankID:      bankID,
		Currency:    normalizedCurrency,
		Amount:      parsedAmount,
		Reason:      strings.TrimSpace(reason),
		Status:      "PENDING",
		RequestedAt: timestampToRFC3339(requestedAt),
	}

	if err := pc.saveMintRequest(ctx, request); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(request)
	_ = ctx.GetStub().SetEvent("MintRequestCreated", eventJSON)

	return request, nil
}

// GetOwnMintRequests returns all mint requests for a bank.
func (pc *ParticipantChaincode) GetOwnMintRequests(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) ([]*MintRequest, error) {
	return pc.listMintRequests(ctx, func(request *MintRequest) bool {
		return request.BankID == bankID
	})
}

// GetOwnMintRequestById returns a single mint request for the requesting bank.
func (pc *ParticipantChaincode) GetOwnMintRequestById(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	requestID string,
) (*MintRequest, error) {
	request, err := pc.getMintRequest(ctx, requestID)
	if err != nil {
		return nil, err
	}

	if request.BankID != bankID {
		return nil, fmt.Errorf("mint request %s does not belong to bank %s", requestID, bankID)
	}

	return request, nil
}

// GetAllMintRequests returns all mint requests. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetAllMintRequests(
	ctx contractapi.TransactionContextInterface,
) ([]*MintRequest, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetAllMintRequests"); err != nil {
		return nil, err
	}

	return pc.listMintRequests(ctx, nil)
}

// GetPendingMintRequests returns pending mint requests. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetPendingMintRequests(
	ctx contractapi.TransactionContextInterface,
) ([]*MintRequest, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetPendingMintRequests"); err != nil {
		return nil, err
	}

	return pc.listMintRequests(ctx, func(request *MintRequest) bool {
		return request.Status == "PENDING"
	})
}

// GetApprovedMintHistory returns approved mint requests. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetApprovedMintHistory(
	ctx contractapi.TransactionContextInterface,
) ([]*MintRequest, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetApprovedMintHistory"); err != nil {
		return nil, err
	}

	return pc.listMintRequests(ctx, func(request *MintRequest) bool {
		return request.Status == "APPROVED"
	})
}

// GetMintRequestById returns a mint request. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetMintRequestById(
	ctx contractapi.TransactionContextInterface,
	requestID string,
) (*MintRequest, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetMintRequestById"); err != nil {
		return nil, err
	}

	return pc.getMintRequest(ctx, requestID)
}

// ApproveMintRequest approves a pending request and credits the participant wallet.
func (pc *ParticipantChaincode) ApproveMintRequest(
	ctx contractapi.TransactionContextInterface,
	requestID string,
) (*MintRequest, error) {
	reviewerID, err := pc.VerifyBetweenNetworkAdmin(ctx, "ApproveMintRequest")
	if err != nil {
		return nil, err
	}

	request, err := pc.getMintRequest(ctx, requestID)
	if err != nil {
		return nil, err
	}

	if request.Status != "PENDING" {
		return nil, fmt.Errorf("mint request %s status is %s; PENDING required", requestID, request.Status)
	}

	if _, err := pc.requireParticipantStatus(ctx, request.BankID, "ACTIVE"); err != nil {
		return nil, err
	}

	wallet, err := pc.creditWallet(ctx, request.BankID, request.Currency, request.Amount)
	if err != nil {
		return nil, err
	}

	reviewedAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	reviewedAtStr := timestampToRFC3339(reviewedAt)
	txID := ctx.GetStub().GetTxID()
	request.Status = "APPROVED"
	request.ReviewedAt = &reviewedAtStr
	request.ReviewedBy = &reviewerID
	request.RejectionReason = nil
	request.ApprovalTxID = &txID
	request.WalletSnapshotID = &wallet.WalletID

	if err := pc.saveMintRequest(ctx, request); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(map[string]interface{}{
		"requestId": request.RequestID,
		"bankId":    request.BankID,
		"currency":  request.Currency,
		"amount":    request.Amount,
		"walletId":  wallet.WalletID,
		"status":    request.Status,
	})
	_ = ctx.GetStub().SetEvent("MintRequestApproved", eventJSON)

	return request, nil
}

// RejectMintRequest rejects a pending mint request. BetweenNetwork admin only.
func (pc *ParticipantChaincode) RejectMintRequest(
	ctx contractapi.TransactionContextInterface,
	requestID string,
	rejectionReason string,
) (*MintRequest, error) {
	reviewerID, err := pc.VerifyBetweenNetworkAdmin(ctx, "RejectMintRequest")
	if err != nil {
		return nil, err
	}

	request, err := pc.getMintRequest(ctx, requestID)
	if err != nil {
		return nil, err
	}

	if request.Status != "PENDING" {
		return nil, fmt.Errorf("mint request %s status is %s; PENDING required", requestID, request.Status)
	}

	reviewedAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	reviewedAtStr := timestampToRFC3339(reviewedAt)
	reason := strings.TrimSpace(rejectionReason)
	request.Status = "REJECTED"
	request.ReviewedAt = &reviewedAtStr
	request.ReviewedBy = &reviewerID
	request.RejectionReason = &reason
	request.ApprovalTxID = nil
	request.WalletSnapshotID = nil

	if err := pc.saveMintRequest(ctx, request); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(map[string]interface{}{
		"requestId":       request.RequestID,
		"bankId":          request.BankID,
		"status":          request.Status,
		"rejectionReason": reason,
	})
	_ = ctx.GetStub().SetEvent("MintRequestRejected", eventJSON)

	return request, nil
}

// ValidateSettlement checks both participants, currency, amount, and routing values.
func (pc *ParticipantChaincode) ValidateSettlement(
	ctx contractapi.TransactionContextInterface,
	fromBank string,
	toBank string,
	currency string,
	amount string,
) (bool, error) {
	if strings.TrimSpace(fromBank) == "" || strings.TrimSpace(toBank) == "" {
		return false, fmt.Errorf("fromBank and toBank are required")
	}

	if fromBank == toBank {
		return false, fmt.Errorf("fromBank and toBank must be different")
	}

	if _, err := pc.requireParticipantStatus(ctx, fromBank, "ACTIVE"); err != nil {
		return false, err
	}

	if _, err := pc.requireParticipantStatus(ctx, toBank, "ACTIVE"); err != nil {
		return false, err
	}

	if normalizeCurrency(currency) == "" {
		return false, fmt.Errorf("currency is required")
	}

	parsedAmount, err := strconv.ParseInt(amount, 10, 64)
	if err != nil || parsedAmount <= 0 {
		return false, fmt.Errorf("amount must be a positive integer")
	}

	return true, nil
}

// HasSufficientBalance returns true if the sender wallet has enough balance for the currency.
func (pc *ParticipantChaincode) HasSufficientBalance(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	currency string,
	amount string,
) (bool, error) {
	if _, err := pc.requireParticipantStatus(ctx, bankID, "ACTIVE"); err != nil {
		return false, err
	}

	parsedAmount, err := strconv.ParseInt(amount, 10, 64)
	if err != nil || parsedAmount <= 0 {
		return false, fmt.Errorf("amount must be a positive integer")
	}

	wallet, err := pc.getWallet(ctx, bankID)
	if err != nil {
		return false, err
	}

	return pc.hasSufficientBalanceInWallet(wallet, currency, parsedAmount), nil
}

// CheckDuplicateSettlement checks if a non-rejected settlement with the same business tuple already exists.
func (pc *ParticipantChaincode) CheckDuplicateSettlement(
	ctx contractapi.TransactionContextInterface,
	fromBank string,
	toBank string,
	currency string,
	amount string,
	reference string,
) (bool, error) {
	parsedAmount, err := strconv.ParseInt(amount, 10, 64)
	if err != nil || parsedAmount <= 0 {
		return false, fmt.Errorf("amount must be a positive integer")
	}

	normalizedCurrency := normalizeCurrency(currency)
	normalizedReference := strings.TrimSpace(reference)

	settlements, err := pc.listSettlements(ctx, func(settlement *Settlement) bool {
		return settlement.FromBank == fromBank &&
			settlement.ToBank == toBank &&
			settlement.Currency == normalizedCurrency &&
			settlement.Amount == parsedAmount &&
			strings.TrimSpace(settlement.Reference) == normalizedReference &&
			settlement.Status != "REJECTED"
	})
	if err != nil {
		return false, err
	}

	return len(settlements) > 0, nil
}

// CreateSettlementRequest creates a pending settlement request.
func (pc *ParticipantChaincode) CreateSettlementRequest(
	ctx contractapi.TransactionContextInterface,
	fromBank string,
	toBank string,
	currency string,
	amount string,
	reference string,
	purpose string,
) (*Settlement, error) {
	if _, err := pc.ValidateSettlement(ctx, fromBank, toBank, currency, amount); err != nil {
		return nil, err
	}

	isDuplicate, err := pc.CheckDuplicateSettlement(ctx, fromBank, toBank, currency, amount, reference)
	if err != nil {
		return nil, err
	}
	if isDuplicate {
		return nil, fmt.Errorf("duplicate settlement detected for reference %s", strings.TrimSpace(reference))
	}

	parsedAmount, _ := strconv.ParseInt(amount, 10, 64)
	createdAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	settlement := &Settlement{
		SettlementID: ctx.GetStub().GetTxID(),
		FromBank:     fromBank,
		ToBank:       toBank,
		Currency:     normalizeCurrency(currency),
		Amount:       parsedAmount,
		Reference:    strings.TrimSpace(reference),
		Purpose:      strings.TrimSpace(purpose),
		Status:       "PENDING",
		CreatedAt:    timestampToRFC3339(createdAt),
	}

	if err := pc.saveSettlement(ctx, settlement); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(settlement)
	_ = ctx.GetStub().SetEvent("SettlementCreated", eventJSON)

	return settlement, nil
}

// ApproveSettlement marks a pending settlement as approved. BetweenNetwork admin only.
func (pc *ParticipantChaincode) ApproveSettlement(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (*Settlement, error) {
	approverID, err := pc.VerifyBetweenNetworkAdmin(ctx, "ApproveSettlement")
	if err != nil {
		return nil, err
	}

	settlement, err := pc.getSettlement(ctx, settlementID)
	if err != nil {
		return nil, err
	}

	if settlement.Status != "PENDING" {
		return nil, fmt.Errorf("settlement %s status is %s; PENDING required", settlementID, settlement.Status)
	}

	approvedAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	approvedAtStr := timestampToRFC3339(approvedAt)
	settlement.Status = "APPROVED"
	settlement.ApprovedAt = &approvedAtStr
	settlement.ApprovedBy = &approverID
	settlement.RejectionReason = nil

	if err := pc.saveSettlement(ctx, settlement); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(settlement)
	_ = ctx.GetStub().SetEvent("SettlementApproved", eventJSON)

	return settlement, nil
}

// RejectSettlement marks a pending settlement as rejected. BetweenNetwork admin only.
func (pc *ParticipantChaincode) RejectSettlement(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
	rejectionReason string,
) (*Settlement, error) {
	_, err := pc.VerifyBetweenNetworkAdmin(ctx, "RejectSettlement")
	if err != nil {
		return nil, err
	}

	settlement, err := pc.getSettlement(ctx, settlementID)
	if err != nil {
		return nil, err
	}

	if settlement.Status != "PENDING" && settlement.Status != "APPROVED" {
		return nil, fmt.Errorf("settlement %s status is %s; PENDING or APPROVED required", settlementID, settlement.Status)
	}

	reason := strings.TrimSpace(rejectionReason)
	settlement.Status = "REJECTED"
	settlement.RejectionReason = &reason
	settlement.CompletedAt = nil
	settlement.ExecutedBy = nil
	settlement.ExecutionTxID = nil

	if err := pc.saveSettlement(ctx, settlement); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(settlement)
	_ = ctx.GetStub().SetEvent("SettlementRejected", eventJSON)

	return settlement, nil
}

// ExecuteSettlement performs the debit/credit and marks the settlement completed. BetweenNetwork admin only.
func (pc *ParticipantChaincode) ExecuteSettlement(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (*Settlement, error) {
	executorID, err := pc.VerifyBetweenNetworkAdmin(ctx, "ExecuteSettlement")
	if err != nil {
		return nil, err
	}

	settlement, err := pc.getSettlement(ctx, settlementID)
	if err != nil {
		return nil, err
	}

	if settlement.Status == "COMPLETED" {
		return nil, fmt.Errorf("settlement %s already completed", settlementID)
	}

	if settlement.Status != "APPROVED" {
		return nil, fmt.Errorf("settlement %s status is %s; APPROVED required", settlementID, settlement.Status)
	}

	if _, err := pc.ValidateSettlement(ctx, settlement.FromBank, settlement.ToBank, settlement.Currency, strconv.FormatInt(settlement.Amount, 10)); err != nil {
		return nil, err
	}

	hasBalance, err := pc.HasSufficientBalance(ctx, settlement.FromBank, settlement.Currency, strconv.FormatInt(settlement.Amount, 10))
	if err != nil {
		return nil, err
	}
	if !hasBalance {
		return nil, fmt.Errorf("insufficient balance for settlement %s", settlementID)
	}

	if _, err := pc.debitWallet(ctx, settlement.FromBank, settlement.Currency, settlement.Amount); err != nil {
		return nil, err
	}
	if _, err := pc.creditWallet(ctx, settlement.ToBank, settlement.Currency, settlement.Amount); err != nil {
		return nil, err
	}

	completedAt, err := stubTimestampAsTime(ctx)
	if err != nil {
		return nil, err
	}

	completedAtStr := timestampToRFC3339(completedAt)
	txID := ctx.GetStub().GetTxID()
	settlement.Status = "COMPLETED"
	settlement.CompletedAt = &completedAtStr
	settlement.ExecutedBy = &executorID
	settlement.ExecutionTxID = &txID

	if err := pc.saveSettlement(ctx, settlement); err != nil {
		return nil, err
	}

	eventJSON, _ := json.Marshal(settlement)
	_ = ctx.GetStub().SetEvent("SettlementCompleted", eventJSON)

	return settlement, nil
}

// GetSettlementById returns a settlement by ID. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetSettlementById(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (*Settlement, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetSettlementById"); err != nil {
		return nil, err
	}

	return pc.getSettlement(ctx, settlementID)
}

// GetSettlementStatus returns the settlement status. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetSettlementStatus(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (string, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetSettlementStatus"); err != nil {
		return "", err
	}

	settlement, err := pc.getSettlement(ctx, settlementID)
	if err != nil {
		return "", err
	}

	return settlement.Status, nil
}

// GetOwnSettlementHistory returns settlements where the bank is either sender or receiver.
func (pc *ParticipantChaincode) GetOwnSettlementHistory(
	ctx contractapi.TransactionContextInterface,
	bankID string,
) ([]*Settlement, error) {
	return pc.listSettlements(ctx, func(settlement *Settlement) bool {
		return settlement.FromBank == bankID || settlement.ToBank == bankID
	})
}

// GetAllSettlements returns the full settlement history. BetweenNetwork admin only.
func (pc *ParticipantChaincode) GetAllSettlements(
	ctx contractapi.TransactionContextInterface,
) ([]*Settlement, error) {
	if _, err := pc.VerifyBetweenNetworkAdmin(ctx, "GetAllSettlements"); err != nil {
		return nil, err
	}

	return pc.listSettlements(ctx, nil)
}

// InvestigateSettlement returns a simple stop-point view for a settlement.
func (pc *ParticipantChaincode) InvestigateSettlement(
	ctx contractapi.TransactionContextInterface,
	settlementID string,
) (*SettlementInvestigation, error) {
	settlement, err := pc.getSettlement(ctx, settlementID)
	if err != nil {
		return nil, err
	}

	investigation := &SettlementInvestigation{
		SettlementID:  settlement.SettlementID,
		CurrentStatus: settlement.Status,
		LastUpdatedAt: settlement.CreatedAt,
		ActionHistory: []map[string]string{
			{
				"step":      "CREATED",
				"status":    "PENDING",
				"timestamp": settlement.CreatedAt,
			},
		},
	}

	switch settlement.Status {
	case "PENDING":
		investigation.StoppedAtStep = "APPROVAL_PENDING"
		investigation.PendingWith = "BETWEENNETWORK_ADMIN"
		investigation.Reason = "Settlement is waiting for approval"
	case "APPROVED":
		investigation.StoppedAtStep = "EXECUTION_PENDING"
		investigation.PendingWith = "BETWEENNETWORK_ADMIN"
		investigation.Reason = "Settlement approved and waiting for execution"
	case "REJECTED":
		investigation.StoppedAtStep = "REJECTED"
		investigation.PendingWith = "NONE"
		if settlement.RejectionReason != nil {
			investigation.Reason = *settlement.RejectionReason
		}
	case "COMPLETED":
		investigation.StoppedAtStep = "COMPLETED"
		investigation.PendingWith = "NONE"
		investigation.Reason = "Settlement completed successfully"
	}

	if settlement.ApprovedAt != nil {
		investigation.LastUpdatedAt = *settlement.ApprovedAt
		investigation.ActionHistory = append(investigation.ActionHistory, map[string]string{
			"step":      "APPROVED",
			"status":    "APPROVED",
			"timestamp": *settlement.ApprovedAt,
		})
	}

	if settlement.CompletedAt != nil {
		investigation.LastUpdatedAt = *settlement.CompletedAt
		investigation.ActionHistory = append(investigation.ActionHistory, map[string]string{
			"step":      "COMPLETED",
			"status":    "COMPLETED",
			"timestamp": *settlement.CompletedAt,
		})
	}

	if settlement.Status == "REJECTED" {
		investigation.ActionHistory = append(investigation.ActionHistory, map[string]string{
			"step":      "REJECTED",
			"status":    "REJECTED",
			"timestamp": investigation.LastUpdatedAt,
		})
	}

	return investigation, nil
}

// GetParticipantByMSP retrieves a participant by MSP ID
// Note: In a production system, you would maintain an MSP->BankID index
// For this implementation, you would need to query by bankId if you have it
func (pc *ParticipantChaincode) GetParticipantByMSP(
	ctx contractapi.TransactionContextInterface,
	mspID string,
) (*Participant, error) {
	// Retrieve all participants using GetStateByRange
	// Start and end keys empty means get all keys
	iterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return nil, fmt.Errorf("failed to get state range: %v", err)
	}
	defer iterator.Close()

	for iterator.HasNext() {
		result, err := iterator.Next()
		if err != nil {
			return nil, err
		}

		var participant Participant
		err = json.Unmarshal(result.Value, &participant)
		if err != nil {
			continue // Skip if not a valid participant
		}

		if participant.MspID == mspID {
			return &participant, nil
		}
	}

	return nil, fmt.Errorf("participant with MSP ID %s not found", mspID)
}

// SuspendParticipant suspends a participant
// ONLY BetweenMSP can invoke this function
// Any other MSP will be rejected with authorization error
func (pc *ParticipantChaincode) SuspendParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	reason string,
) error {
	// ========== AUTHORIZATION CHECK ==========
	// Verify only BetweenMSP can suspend participants
	clientID, err := pc.VerifyBetweenNetworkAdmin(ctx, "SuspendParticipant")
	if err != nil {
		log.Printf("AUTHORIZATION DENIED - SuspendParticipant: %v", err)
		return err
	}

	// Get participant
	participant, err := pc.GetParticipant(ctx, bankID)
	if err != nil {
		return err
	}

	// Get transaction timestamp
	txTimestamp, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("failed to get tx timestamp: %v", err)
	}

	// Update status
	participant.Status = "SUSPENDED"
	participant.LastModifiedBy = clientID
	participant.LastModifiedDate = txTimestamp.String()

	// Save to ledger
	participantJSON, err := json.Marshal(participant)
	if err != nil {
		return fmt.Errorf("failed to marshal participant: %v", err)
	}

	err = ctx.GetStub().PutState(bankID, participantJSON)
	if err != nil {
		return fmt.Errorf("failed to update participant: %v", err)
	}

	// Emit event
	eventData := map[string]string{
		"bankId": bankID,
		"reason": reason,
	}
	eventJSON, _ := json.Marshal(eventData)
	ctx.GetStub().SetEvent("ParticipantSuspended", eventJSON)

	return nil
}

// RevokeParticipant revokes a participant
// ONLY BetweenMSP can invoke this function
// Any other MSP will be rejected with authorization error
func (pc *ParticipantChaincode) RevokeParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	reason string,
) error {
	// ========== AUTHORIZATION CHECK ==========
	// Verify only BetweenMSP can revoke participants
	clientID, err := pc.VerifyBetweenNetworkAdmin(ctx, "RevokeParticipant")
	if err != nil {
		log.Printf("AUTHORIZATION DENIED - RevokeParticipant: %v", err)
		return err
	}

	// Get participant
	participant, err := pc.GetParticipant(ctx, bankID)
	if err != nil {
		return err
	}

	// Get transaction timestamp
	txTimestamp, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("failed to get tx timestamp: %v", err)
	}

	// Update status
	participant.Status = "REVOKED"
	participant.LastModifiedBy = clientID
	participant.LastModifiedDate = txTimestamp.String()

	// Save to ledger
	participantJSON, err := json.Marshal(participant)
	if err != nil {
		return fmt.Errorf("failed to marshal participant: %v", err)
	}

	err = ctx.GetStub().PutState(bankID, participantJSON)
	if err != nil {
		return fmt.Errorf("failed to revoke participant: %v", err)
	}

	// Emit event
	eventData := map[string]string{
		"bankId": bankID,
		"reason": reason,
	}
	eventJSON, _ := json.Marshal(eventData)
	ctx.GetStub().SetEvent("ParticipantRevoked", eventJSON)

	return nil
}

// ReactivateParticipant reactivates a suspended or revoked participant
// ONLY BetweenMSP can invoke this function
// Any other MSP will be rejected with authorization error
func (pc *ParticipantChaincode) ReactivateParticipant(
	ctx contractapi.TransactionContextInterface,
	bankID string,
	reason string,
) error {
	// ========== AUTHORIZATION CHECK ==========
	// Verify only BetweenMSP can reactivate participants
	clientID, err := pc.VerifyBetweenNetworkAdmin(ctx, "ReactivateParticipant")
	if err != nil {
		log.Printf("AUTHORIZATION DENIED - ReactivateParticipant: %v", err)
		return err
	}

	// Get participant
	participant, err := pc.GetParticipant(ctx, bankID)
	if err != nil {
		return err
	}

	// Get transaction timestamp
	txTimestamp, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("failed to get tx timestamp: %v", err)
	}

	// Update status
	participant.Status = "ACTIVE"
	participant.LastModifiedBy = clientID
	participant.LastModifiedDate = txTimestamp.String()

	// Save to ledger
	participantJSON, err := json.Marshal(participant)
	if err != nil {
		return fmt.Errorf("failed to marshal participant: %v", err)
	}

	err = ctx.GetStub().PutState(bankID, participantJSON)
	if err != nil {
		return fmt.Errorf("failed to reactivate participant: %v", err)
	}

	// Emit event
	eventData := map[string]string{
		"bankId": bankID,
		"reason": reason,
	}
	eventJSON, _ := json.Marshal(eventData)
	ctx.GetStub().SetEvent("ParticipantReactivated", eventJSON)

	return nil
}

// GetAllParticipants retrieves all participants from the ledger
func (pc *ParticipantChaincode) GetAllParticipants(
	ctx contractapi.TransactionContextInterface,
) ([]*Participant, error) {
	// Get all participants using GetStateByRange
	// Empty start and end keys means retrieve all keys
	iterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return nil, fmt.Errorf("failed to get state range: %v", err)
	}
	defer iterator.Close()

	var participants []*Participant
	for iterator.HasNext() {
		result, err := iterator.Next()
		var participant Participant
		err = json.Unmarshal(result.Value, &participant)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal participant: %v", err)
		}

		participants = append(participants, &participant)
	}

	return participants, nil
}

// main starts the chaincode
func main() {
	chaincode, err := contractapi.NewChaincode(&ParticipantChaincode{})
	if err != nil {
		log.Panicf("Error creating participant chaincode: %v", err)
	}

	if err := chaincode.Start(); err != nil {
		log.Panicf("Error starting participant chaincode: %v", err)
	}
}
