# **Library Management System**

EECS 447 — Part 3: Entity-Relationship Modeling

## **1\. Introduction**

### **Project Overview**

The Library Management System is a database for a small library. It stores library items, clients, memberships, loans, reservations, notifications, and late fees. It supports catalog searches, checkouts and returns, borrowing rules, and reports on availability and borrowing activity.

### **Scope**

The project covers books, digital media, magazines, client accounts and membership types, checkouts and returns, reservations, notifications, item restrictions, and late fees. Part 3 models the entities, attributes, relationships, and constraints established in Part 2\. A production interface and integrations with outside library systems are outside the project’s scope.

### **Glossary**

* **Client/Member** — A registered library user with an account who may borrow or reserve eligible items.  
* **Library Item** — An individual book, digital media item, or magazine in the library’s collection.  
* **Membership Type** — A client category that determines the borrowing limit and daily late-fee rate.  
* **Loan** — A record linking a client to a checked-out item, including checkout, due, and return information.  
* **Reservation** — A client’s request for an eligible item that is currently unavailable.  
* **Notification** — Due-date, overdue, or reservation notice  
* **Late Fee** — An amount owed for an overdue loan, calculated according to the applicable membership rate and library rules.

## **2\. Identify ER Modeling Components**

### **Identify Entities**

Part 2 identifies these seven entities:

| Entity | Description |
| ----- | ----- |
| Library Item | Book, digital media item, or magazine |
| Client | Library member and account |
| Membership Type | Sets borrowing limit and daily late-fee rate |
| Loan | Item checkout and return |
| Reservation | Request for an item currently on loan |
| Notification | Due-date, overdue, or reservation notice |
| Late Fee | Amount owed and paid for an overdue loan |

Library Item covers books, digital media, and magazines. Loan records returns. Reports use these records.

### **Define Attributes**

Each entity has a primary key. IDs that link entities are foreign keys. Other attributes are required for the item types they apply to unless marked optional.

#### **Library Item**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Item ID | int | Primary key |
| Title | Text | Required |
| Item Type | Text | Book, digital media, or magazine |
| Availability Status | Text | Matches circulation records |
| Borrowing Restricted | bool | Shows if checkout is restricted |
| Author/Creator | Text | Books and digital media only |
| ISBN | Text | Optional, not the primary key |
| Publication Year | int | Books and digital media only |
| Genre | Text | Books and digital media only |
| Issue Number | Text | Magazines only |
| Publication Date | Date | Magazines only |

#### **Client**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Client ID | int | Primary key |
| First Name | Text | Required |
| Last Name | Text | Required |
| Phone Number | Text | Required |
| Membership Type ID | int | Foreign key to Membership Type |
| Account Status | Text | Active, inactive, or restricted |

#### **Membership Type**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Membership Type ID | int | Primary key |
| Name | Text | Required |
| Borrowing Limit | int | 0 or more |
| Daily Late-Fee Rate | Decimal | 0 or more |

#### **Loan**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Loan ID | int | Primary key |
| Item ID | int | Foreign key to Library Item |
| Client ID | int | Foreign key to Client |
| Checkout Timestamp | Timestamp | Required |
| Due Date | Date | On or after checkout date |
| Return Timestamp | Timestamp | Blank until return, then on or after checkout |

#### **Reservation**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Reservation ID | int | Primary key |
| Client ID | int | Foreign key to Client |
| Item ID | int | Foreign key to Library Item |
| Reservation Date | Date | Required |
| Reservation Status | Text | Pending, available, fulfilled, or cancelled |

#### **Notification**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Notification ID | int | Primary key |
| Client ID | int | Foreign key to Client |
| Loan ID | int | Foreign key to Loan for due-soon or overdue notices |
| Reservation ID | int | Foreign key to Reservation for available-reservation notices |
| Notification Type | Text | Upcoming due date, overdue loan, or available reservation |
| Message | Text | Required |
| Creation Timestamp | Timestamp | Required |

Each notification uses either Loan ID or Reservation ID, based on its type.

#### **Late Fee**

| Attribute | Data Type | Constraints |
| ----- | ----- | ----- |
| Fee ID | int | Primary key |
| Loan ID | int | Foreign key to Loan, one fee per loan |
| Amount Owed | Decimal | 0 or more |
| Amount Paid | Decimal | 0 or more |

### **Define Relationships**

The table shows how many records can be linked on each side, including past loans and reservations.

| Relationship | One side | Other side | Multiplicity |
| ----- | ----- | ----- | ----- |
| Membership Type–Client | Client: 1..1 Membership Type | Membership Type: 0..\* Clients | One-to-many |
| Client–Loan | Loan: 1..1 Client | Client: 0..\* Loans | One-to-many |
| Library Item–Loan | Loan: 1..1 Library Item | Library Item: 0..\* Loans | One-to-many |
| Client–Reservation | Reservation: 1..1 Client | Client: 0..\* Reservations | One-to-many |
| Library Item–Reservation | Reservation: 1..1 Library Item | Library Item: 0..\* Reservations | One-to-many |
| Client–Notification | Notification: 1..1 Client | Client: 0..\* Notifications | One-to-many |
| Loan–Notification | Notification: 0..1 Loan | Loan: 0..\* Notifications | One-to-many |
| Reservation–Notification | Notification: 0..1 Reservation | Reservation: 0..\* Notifications | One-to-many |
| Loan–Late Fee | Late Fee: 1..1 Loan | Loan: 0..1 Late Fee | One-to-one |

Loan and Reservation link clients and items over time. Together, they form many-to-many relationships between clients and items.

### **Additional Constraints**

An item can have only one active loan at a time. Checkout must follow membership limits and client and item restrictions. An item with an active loan or reservation cannot be removed. Due dates and return timestamps cannot be before checkout. Each notification must link to a loan or reservation for the same client.

## **3\. ER Model (also attached as pdf, see Github)**

[View the separate ER diagram PDF](PART_3_ER_DIAGRAM.pdf)

## **Project Meeting Log**

### **Meeting: Sep 27, 2026**

Time: 5 PM

Objective: Review Part 3 requirements and divide the work

Team Members Present: Pranav, Mo, Gabe, Karim, Dani

### **Tasks Completed**

* Reviewed Part 3 requirements and the Part 2 document  
* Pranav and Mo completed the introduction  
* Started planning the entities, attributes, and relationships

### **Tasks Allocated**

* Karim, Dani, and Gabe: Identify ER Modeling Components  
* Pranav: ER diagram and coordination  
* Mo: Meeting log and later ER diagram review

Deadline: Oct 4, 2026

### **Follow-Up Action**

* Finish the ER components and use them to create the diagram

### **Meeting: Oct 4, 2026**

Time: 5 PM

Objective: Complete and review the Part 3 ER model

Team Members Present: Pranav, Mo, Gabe, Karim, Dani

### **Tasks Completed**

* Karim and Dani almost completed the ER components  
* Pranav and Gabe planning out ER diagram in Visual Paradigm  
* Reviewed the model against Part 2 and corrected diagram issues  
* Checked primary keys, cardinalities, and mandatory participation

### **Tasks Allocated**

* Pranav: Final document, diagram, and submission  
* Mo: Review diagram and meeting log  
* Gabe, Karim, and Dani: Final review and tighten ER components

Deadline: Before Part 3 submission

### **Follow-Up Action**

* Team: Review the final document and diagram  
* Pranav: Add the final files to GitHub and submit
