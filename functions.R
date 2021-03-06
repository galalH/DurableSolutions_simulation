########################################################
# Functions to implement different metrics for solutions
########################################################

library(tidyverse)

# Utility functions ----
calculate_composite <- function(data, sim_data, benchmark, x, grouping) {
  data <- bind_rows(data, benchmark) %>% select(ID, all_of(as.character(sim_data[x,]))) %>% mutate(hhid = row_number())
  
  newdata <- 
    data %>% 
    pivot_longer(-c(ID, hhid), names_to = "ind", values_to = "val") %>% 
    mutate(ind = str_match(ind, "^(I\\d+)")[,2],
           grp = grouping[ind]) %>% 
    group_by(ID, hhid, grp) %>% 
    summarize(val = sum(val), .groups = "drop")
  
  benchmark <- newdata %>% filter(ID == 0) %>% group_by(grp) %>% summarize(benchmark = mean(val, na.rm = TRUE))
  
  idps <- 
    newdata %>% 
    filter(ID == 1) %>% 
    left_join(benchmark, by = "grp") %>% 
    group_by(hhid) %>% 
    summarize(exited = all(val >= benchmark))
  
  sum(idps$exited, na.rm = TRUE)
}

optimum_threshold <- function(ID, p) {
  roc_curve <- tibble(threshold = unique(p),
                      sensitivity = map_dbl(threshold, ~sum((p>.)*ID)/sum(ID)),
                      specificity = map_dbl(threshold, ~sum((p<.)*(!ID))/sum(!ID)))
  
  roc_curve %>% 
    arrange(desc(sensitivity+specificity)) %>% 
    pluck("threshold", 1)
}

# Original framework function --------------------------------------
use_IRIS_metric <- function(data, sim_data, benchmark, x){
  # first only select the relevant variable for this simulation
  select_var = data[,as.character(sim_data[x,])]
  # then check whether any of them is zero (not passed)
  passed = select_var %>% filter(across(everything(), ~ .==1))
  # then count how many have passed on all dimensions
  nrow(passed)
}

# Option 1: Full composite ------------------------------------------
use_composite <- function(data, sim_data, benchmark, x) {
  grouping <- rep("-", 10) %>% set_names(str_c("I", 1:10))
  
  calculate_composite(data, sim_data, benchmark, x, grouping = grouping)
}

# Option 2: Composite measure at criterion level -----------------------------------
use_criterion <- function(data, sim_data, benchmark, x){
  grouping <- c(I1 = "C1", I2 = "C2",
                I3 = "C2", I4 = "C2", I5 = "C2", I6 = "C2",
                I7 = "C3", I8 = "C3",
                I9 = "C4",
                I10 = "C5")
  
  calculate_composite(data, sim_data, benchmark, x, grouping = grouping)
}

# Option 3: Composite measure at subcriterion level -----------------------------------
use_subcriterion <- function(data, sim_data, benchmark, x){
  grouping <- str_c("SC", 1:10) %>% set_names(str_c("I", 1:10))
  
  calculate_composite(data, sim_data, benchmark, x, grouping = grouping)
}

# Option 4: Use population cells ------------------------------------------------------
use_cells <- function(x, y, data, benchmark, combination_cells, sim_data){
  combination_indicators <- sim_data
  
  averages_per_cell = data %>% 
    select(-ID) %>% 
    group_by_at(vars(one_of(as.character(combination_cells[x,])))) %>% 
    summarise(across(-starts_with("HH_"), mean, na.rm = T), n = n(), .groups = "drop") %>% 
    select(as.character(combination_indicators[y,]),n) 
  
  benchmark = benchmark %>% select(as.character(combination_indicators[y,])) %>% summarise_all(mean, na.rm = T)
  
  # make comparison
  assessment_per_cell = averages_per_cell %>% 
    filter(across(starts_with("I"), ~. >= as.numeric(benchmark[,cur_column()])))
  
  sum(assessment_per_cell$n, na.rm =T)
}

# Option 4b: Use population cells w/hclust ------------------------------------------
use_hclust <- function(data, sim_data, benchmark, x, method, maxdiff) {
  benchmark <- benchmark %>% select(as.character(sim_data[x,])) %>% summarize(across(everything(), mean, na.rm = TRUE))
  data <- data %>% select(as.character(sim_data[x,])) %>% drop_na()
  
  h <- data %>% dist(method = "binary") %>% hclust(method = method)
  
  data <- data %>% mutate(cell = cutree(h, h = maxdiff/ncol(data)))
  
  averages_per_cell <- data %>% group_by(cell) %>% summarize(across(everything(), mean), n = n())
  
  assessment_per_cell <- averages_per_cell %>% 
    filter(across(starts_with("I"), ~. >= as.numeric(benchmark[,cur_column()])))
  
  sum(assessment_per_cell$n)
}

# Option 5: Use a classifier ------------------------------------------------------------
use_classifier <- function(data,sim_data,benchmark,x){
  
  # select the right variables per iteration
  data = bind_rows(data, benchmark) %>% select(ID, as.character(sim_data[x,])) %>% drop_na()
  names(data) = sub("\\_.*", "", names(data))
  
  # fit the model to classify
  model = glm(ID ~ ., family = "binomial", data = data %>% select(starts_with("I")))
  
  # predict whether IDP or non-displaced
  data$IDP_prob <- predict(model, data, type= "response")
  threshold <- optimum_threshold(data$ID, data$IDP_prob)
  data <- data %>% 
  mutate(IDP_pred = case_when(
    ID == 0 ~ 0,
    IDP_prob > threshold ~ 1, 
    IDP_prob < threshold ~ 0,
    TRUE ~ 1))
  
  # identify how many leave the stock of IDPs
  as.integer(sum(data$ID-data$IDP_pred))
}

# Option 5b: Use a classifier w/Lasso regularization ----------------------------------
use_lasso <- function(data) {
  x <- data %>% drop_na() %>% select(-ID) %>% data.matrix()
  y <- data %>% drop_na() %>% pull(ID)
  
  m <- glmnet::cv.glmnet(x, y, family = "binomial")
  
  p <- predict(m, newx = x, s = "lambda.1se", type = "response")[,1]

  t <- optimum_threshold(y, p)
  
  sum((p<t)*y)
}